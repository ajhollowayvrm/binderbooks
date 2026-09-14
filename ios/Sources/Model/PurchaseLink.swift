import Foundation
import SwiftData

/// Puts cards he already holds onto a purchase he already recorded.
///
/// Many cards reached inventory with no purchase behind them: a scan committed
/// with no purchase, a card added by hand, a row from the old ledger. The money
/// is on the books and the cards are on the books. This joins the two, so each
/// card takes its share of what the purchase cost. See "Choosing a purchase" in
/// docs/02.
@MainActor
enum PurchaseLink {
    struct Result: Equatable {
        /// Cards that moved. A card already on the purchase is not counted.
        var linked = 0
        /// False when the purchase did not split again, because a card on it
        /// carries a cost the split did not write. See `PurchaseEditor.canResplit`.
        var split = true
        /// Order lines of sold cards that had no known cost and now have one.
        var filledSaleLines = 0
    }

    @discardableResult
    static func link(_ cards: [OwnedCard], to purchase: Purchase, context: ModelContext) throws -> Result {
        var result = Result()
        var left: [Purchase] = []

        for card in cards where card.sourceItem?.purchase?.id != purchase.id {
            if let old = card.sourceItem?.purchase, !left.contains(where: { $0.id == old.id }) {
                left.append(old)
            }
            // A box bought several at a time shares one line. Only this box moves.
            if card.isSealedSelf {
                _ = Allocation.isolate(card, context: context)
                try context.save()
            }
            if let line = card.sourceItem, line.cards.allSatisfy({ $0.id == card.id }) {
                // Alone on its line, the card moves with the line. A scan session
                // can rip from this line, so it is never left behind or deleted.
                line.purchase = purchase
            } else {
                // Pulls from one pack share a line. This one gets its own, the
                // way a scan commit gives each card a line.
                let line = PurchaseItem(productId: card.productId, quantity: 1, isSealed: card.isSealedSelf)
                context.insert(line)
                line.purchase = purchase
                card.sourceItem = line
            }
            if !card.basisIsManual, !card.isBulk {
                if card.acquisitionBasisCents == 0 {
                    // No cost yet, so the card takes its share.
                    card.basisIsAllocated = true
                } else if !card.basisIsAllocated {
                    // A cost he typed, or one the old ledger carried, stays his.
                    // It comes out of the purchase total first.
                    card.basisIsManual = true
                }
            }
            card.acquiredAt = purchase.date
            result.linked += 1
            try context.save()
        }
        guard result.linked > 0 else { return result }

        result.split = PurchaseEditor.resplitIfSafe(purchase)
        for old in left {
            _ = PurchaseEditor.resplitIfSafe(old)
        }
        try context.save()

        // A sold card whose order recorded no cost takes the cost it has now.
        // A cost the order already knows is never replaced.
        let ids = Set(cards.map(\.id))
        let open = try context.fetch(FetchDescriptor<SaleLine>(predicate: #Predicate { $0.basisIncomplete == true }))
        for line in open {
            guard let card = line.card, ids.contains(card.id), let basis = SaleEditor.knownBasis(card) else { continue }
            try SaleEditor.setCost(basis, on: line, context: context)
            result.filledSaleLines += 1
        }
        return result
    }
}
