import Foundation
import SwiftData

/// The edits to a purchase after it is on the books.
@MainActor
enum PurchaseEditor {
    /// What the edit sheet changes.
    struct Details: Equatable {
        var date: Date
        var vendor: String
        var note: String
        var itemCostCents: Int
        var shippingCents: Int
        var taxCents: Int
        var feesCents: Int

        init(_ purchase: Purchase) {
            date = purchase.date
            vendor = purchase.vendor
            note = purchase.note
            itemCostCents = purchase.itemCostCents
            shippingCents = purchase.shippingCents
            taxCents = purchase.taxCents
            feesCents = purchase.feesCents
        }

        var landedCostCents: Int { itemCostCents + shippingCents + taxCents + feesCents }
    }

    /// True when a new total can split again over the purchase's cards.
    ///
    /// The split writes over every card that was not priced by hand. The seed
    /// import wrote a real cost on its cards and marked none of them manual.
    /// So the split must not run while any card carries a cost that the split
    /// did not write. A bulk card has no cost to lose.
    static func canResplit(_ purchase: Purchase, ignoring cardId: UUID? = nil) -> Bool {
        purchase.items.flatMap(\.cards).allSatisfy {
            $0.id == cardId || $0.isBulk || $0.basisIsManual || $0.basisIsAllocated
        }
    }

    /// Returns true when the cards took a new split.
    @discardableResult
    static func apply(_ details: Details, to purchase: Purchase, context: ModelContext) throws -> Bool {
        let oldDate = purchase.date
        let totalChanged = details.landedCostCents != purchase.landedCostCents
        purchase.date = details.date
        purchase.vendor = details.vendor.trimmingCharacters(in: .whitespaces)
        purchase.note = details.note.trimmingCharacters(in: .whitespaces)
        purchase.itemCostCents = details.itemCostCents
        purchase.shippingCents = details.shippingCents
        purchase.taxCents = details.taxCents
        purchase.feesCents = details.feesCents
        if details.date != oldDate {
            // A card takes its purchase's date at intake. Only those cards move.
            for card in purchase.items.flatMap(\.cards) where card.acquiredAt == oldDate {
                card.acquiredAt = details.date
            }
        }
        let resplit = totalChanged && resplitIfSafe(purchase)
        try context.save()
        return resplit
    }

    /// Splits the total again when `canResplit` allows it. Returns true when it ran.
    static func resplitIfSafe(_ purchase: Purchase) -> Bool {
        guard canResplit(purchase) else { return false }
        Allocation.allocate(purchase)
        Allocation.writeCardBases(purchase)
        return true
    }
}

/// The edits to one card that need rules: its cost, and its catalog product.
@MainActor
enum CardEditor {
    /// What the cost sheet changes.
    struct CostDetails: Equatable {
        var acquiredAt: Date
        var acquisitionBasisCents: Int
        var gradingBasisCents: Int
        /// True when the card takes its share of the purchase, not a typed cost.
        var usesSplit: Bool

        init(_ card: OwnedCard) {
            acquiredAt = card.acquiredAt
            acquisitionBasisCents = card.acquisitionBasisCents
            gradingBasisCents = card.gradingBasisCents
            usesSplit = card.sourceItem?.purchase != nil && !card.basisIsManual && card.basisIsAllocated
        }
    }

    /// True when the card can take its share of its purchase. Every other
    /// card on the purchase must allow a new split.
    static func canUseSplit(_ card: OwnedCard) -> Bool {
        guard let purchase = card.sourceItem?.purchase else { return false }
        return PurchaseEditor.canResplit(purchase, ignoring: card.id)
    }

    /// A typed cost becomes the card's own, and it comes out of the purchase
    /// total. The rest of the purchase splits again when that is safe.
    /// Returns true when the purchase split again.
    @discardableResult
    static func apply(_ details: CostDetails, to card: OwnedCard, context: ModelContext) throws -> Bool {
        let before = CostDetails(card)
        let purchase = card.sourceItem?.purchase
        card.acquiredAt = details.acquiredAt
        card.gradingBasisCents = details.gradingBasisCents

        var resplit = false
        if details.usesSplit, !before.usesSplit, canUseSplit(card), let purchase {
            card.basisIsManual = false
            card.basisIsAllocated = true
            resplit = PurchaseEditor.resplitIfSafe(purchase)
        } else if !details.usesSplit, before.usesSplit || details.acquisitionBasisCents != before.acquisitionBasisCents {
            card.acquisitionBasisCents = details.acquisitionBasisCents
            card.basisIsManual = true
            card.basisIsAllocated = false
            if let purchase { resplit = PurchaseEditor.resplitIfSafe(purchase) }
        }
        try context.save()
        return resplit
    }

    /// Moves a card to another catalog product. A catalog card keeps its
    /// typed identity fields empty and its language at "en" (see `OwnedCard`),
    /// so a hand-entered card loses them here. The SKU belongs to the old product.
    static func assign(_ card: OwnedCard, toProduct productId: Int, context: ModelContext) throws {
        card.productId = productId
        card.skuId = nil
        card.matchConfidence = .manual
        if !card.candidateProductIds.contains(productId) {
            card.candidateProductIds.insert(productId, at: 0)
        }
        card.manualName = ""
        card.manualSetName = ""
        card.manualNumber = ""
        card.manualMarketCents = nil
        card.language = "en"
        CardPhotoStore.remove([card.id])
        try context.save()
    }
}

extension CardEditor {
    /// True when the card screen offers "add another". A slab is one of a
    /// kind, with its own cert and grade, so it has no plain copy.
    static func canAddCopy(of card: OwnedCard) -> Bool {
        !card.isSlabbed && !CardTagIndex.isSold(card)
    }

    /// One more copy of `card`, from the card screen's plus.
    ///
    /// The copy is the same card: product, printing, condition, language, and
    /// a hand-entered name. What a copy is doing does not carry over: no
    /// labels, no purchase, no cost, not in the personal collection. A bulk
    /// line is one card with a count, so its count goes up instead.
    @discardableResult
    static func addCopy(of card: OwnedCard, context: ModelContext) throws -> OwnedCard {
        if card.isBulk {
            card.quantity = max(1, card.quantity) + 1
            try context.save()
            return card
        }
        let copy = OwnedCard(productId: card.productId, printing: card.printing, condition: card.condition, confidence: .manual)
        copy.language = card.language
        copy.isSealedSelf = card.isSealedSelf
        copy.manualName = card.manualName
        copy.manualSetName = card.manualSetName
        copy.manualNumber = card.manualNumber
        copy.manualMarketCents = card.manualMarketCents
        context.insert(copy)
        CardPhotoStore.copy(from: card.id, to: copy.id)
        try context.save()
        return copy
    }
}
