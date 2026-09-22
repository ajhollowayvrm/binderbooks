import Foundation
import SwiftData

/// The products he names on a purchase while he records it: the sealed box,
/// the packs, or the singles, found in the catalog.
///
/// Each product becomes one `PurchaseItem`, the record of what he bought. Each
/// copy also becomes one card in inventory. A sealed product's cards are the
/// boxes themselves, so he can rip them later. The cards have no link to the
/// purchase and no cost. The purchase total stays on the books as it is.
enum PurchaseIntake {
    struct Line: Identifiable, Hashable {
        var productId: Int
        var name: String
        var setName: String
        var isSealed: Bool
        var quantity: Int = 1
        /// Empty when the catalog has no printing for the product.
        var printing: String = ""
        /// Every printing the catalog prices, for the picker on the row.
        var printings: [String] = []

        var id: Int { productId }
    }

    /// The list with the hit added. A product already on the list takes one
    /// more copy instead of a second row.
    static func adding(_ hit: SearchHit, printings: [String], to lines: [Line]) -> [Line] {
        var out = lines
        if let index = out.firstIndex(where: { $0.productId == hit.productId }) {
            out[index].quantity += 1
            return out
        }
        // The first printing, the same default as `AddToInventorySheet`.
        out.append(Line(
            productId: hit.productId, name: hit.name, setName: hit.setName, isSealed: hit.isSealed,
            printing: printings.first ?? "", printings: printings
        ))
        return out
    }

    /// What a receipt would say: "6x Chaos Rising Booster Pack, Charizard ex".
    static func note(for lines: [Line]) -> String {
        lines.map { $0.quantity > 1 ? "\($0.quantity)x \($0.name)" : $0.name }.joined(separator: ", ")
    }

    /// Writes the lines onto the purchase and adds the cards to inventory.
    /// Returns the new cards.
    @discardableResult
    static func record(_ lines: [Line], on purchase: Purchase, context: ModelContext) -> [OwnedCard] {
        var added: [OwnedCard] = []
        for line in lines where line.quantity > 0 {
            let item = PurchaseItem(productId: line.productId, quantity: line.quantity, isSealed: line.isSealed)
            item.purchase = purchase
            context.insert(item)
            for _ in 0..<line.quantity {
                let card = OwnedCard(productId: line.productId, printing: line.printing, condition: CardCondition.nearMint.rawValue, confidence: .manual)
                card.isSealedSelf = line.isSealed
                card.acquiredAt = purchase.date
                context.insert(card)
                added.append(card)
            }
        }
        return added
    }
}
