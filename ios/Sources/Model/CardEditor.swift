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

    /// Writes the new details onto the purchase. No card changes.
    static func apply(_ details: Details, to purchase: Purchase, context: ModelContext) throws {
        purchase.date = details.date
        purchase.vendor = details.vendor.trimmingCharacters(in: .whitespaces)
        purchase.note = details.note.trimmingCharacters(in: .whitespaces)
        purchase.itemCostCents = details.itemCostCents
        purchase.shippingCents = details.shippingCents
        purchase.taxCents = details.taxCents
        purchase.feesCents = details.feesCents
        try context.save()
    }

    /// Deletes a purchase and keeps every card.
    ///
    /// Old data can still link a card to a purchase line through the dormant
    /// `OwnedCard.sourceItem`. `PurchaseItem.cards` is a cascade relationship,
    /// so deleting the line also deletes those cards. This removes each link
    /// and saves before the purchase goes. Always delete a purchase here.
    static func delete(_ purchase: Purchase, context: ModelContext) throws {
        var lines = purchase.items
        var index = 0
        while index < lines.count {
            lines.append(contentsOf: lines[index].childItems)
            index += 1
        }
        for line in lines {
            for card in line.cards { card.sourceItem = nil }
        }
        try context.save()
        context.delete(purchase)
        try context.save()
    }
}

/// The edits to one card that need rules: its catalog product, and new cards.
@MainActor
enum CardEditor {
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
    /// New cards that he adds to inventory by hand. `quantity` cards of one
    /// product, or of one card he typed himself when `productId` is 0. The
    /// typed name, set, number, value, and language apply only then.
    ///
    /// No purchase and no cost: a card stands alone.
    @discardableResult
    static func addCards(
        productId: Int,
        isSealed: Bool,
        quantity: Int,
        printing: String,
        condition: String,
        manualName: String = "",
        manualSetName: String = "",
        manualNumber: String = "",
        manualMarketCents: Int? = nil,
        language: String = "en",
        context: ModelContext
    ) -> [OwnedCard] {
        let cards = (0..<max(0, quantity)).map { _ -> OwnedCard in
            let card = OwnedCard(productId: productId, printing: printing, condition: condition, confidence: .manual)
            card.isSealedSelf = isSealed
            if productId == 0 {
                card.manualName = manualName.trimmingCharacters(in: .whitespacesAndNewlines)
                card.manualSetName = manualSetName.trimmingCharacters(in: .whitespacesAndNewlines)
                card.manualNumber = manualNumber.trimmingCharacters(in: .whitespacesAndNewlines)
                card.manualMarketCents = manualMarketCents
                card.language = language
            }
            context.insert(card)
            return card
        }
        try? context.save()
        return cards
    }

    /// True when the card screen offers "add another". A slab is one of a
    /// kind, with its own cert and grade, so it has no plain copy.
    static func canAddCopy(of card: OwnedCard) -> Bool {
        !card.isSlabbed && !CardTagIndex.isSold(card)
    }

    /// One more copy of `card`, from the card screen's plus.
    ///
    /// The copy is the same card: product, printing, condition, language, and
    /// a hand-entered name. What a copy is doing does not carry over: no
    /// labels, not in the personal collection. A bulk
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
