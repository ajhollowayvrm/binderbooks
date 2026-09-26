import Foundation
import SwiftData

/// Puts cards he already holds onto a purchase he already recorded.
///
/// Many cards reach inventory with no purchase behind them: a scan committed
/// with no purchase, a card added by hand, a card moved from the wrong
/// purchase. This joins the card to the purchase, so the card takes its share
/// of the landed cost. The purchase splits again by market price, and so does
/// each purchase the cards left. See `CostBasis.split`.
@MainActor
enum PurchaseLink {
    /// Returns the number of cards that moved. A card already on the purchase
    /// does not count.
    ///
    /// `marketCents` must already know the cards on every purchase involved,
    /// or the split is equal.
    @discardableResult
    static func link(
        _ cards: [OwnedCard],
        to purchase: Purchase,
        since start: Date? = Books.start(),
        marketCents: (OwnedCard) -> Int? = { _ in nil },
        context: ModelContext
    ) throws -> Int {
        var moved = 0
        var left: [Purchase] = []

        for card in cards where card.sourceItem?.purchase?.id != purchase.id {
            let old = card.sourceItem
            if let from = old?.purchase, !left.contains(where: { $0.id == from.id }) {
                left.append(from)
            }
            if let old, canMove(old, alone: card) {
                // Alone on a plain line, the card moves with its line. A scan
                // session can point at the line, so a line is never deleted.
                old.purchase = purchase
            } else {
                // A pull from a pack, or one copy of several on a line, gets
                // its own line. The old line lists one copy less.
                if let old, old.quantity > 1 { old.quantity -= 1 }
                let line = PurchaseItem(productId: card.productId, quantity: 1, isSealed: card.isSealedSelf)
                context.insert(line)
                line.purchase = purchase
                card.sourceItem = line
            }
            // A cost he typed stays his. Any other cost comes from the split.
            if !card.basisIsManual {
                card.basisIsAllocated = true
            }
            card.acquiredAt = purchase.date
            moved += 1
        }
        guard moved > 0 else { return 0 }

        CostBasis.split(purchase, since: start, marketCents: marketCents)
        for from in left {
            CostBasis.split(from, since: start, marketCents: marketCents)
        }
        try context.save()
        return moved
    }

    /// True when the line can move to another purchase with the card: the
    /// card is the only card on it, it hangs off no pack, nothing was pulled
    /// from it, and it was not ripped.
    private static func canMove(_ line: PurchaseItem, alone card: OwnedCard) -> Bool {
        line.purchase != nil
            && line.parentItem == nil
            && line.childItems.isEmpty
            && !line.isRipped
            && line.cards.allSatisfy { $0.id == card.id }
    }
}
