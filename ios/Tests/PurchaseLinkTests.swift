import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// Cards he holds join a purchase on the books and take their share of it.
@Suite struct PurchaseLinkTests {
    @MainActor private func store() throws -> ModelContainer {
        try CollectionStore.container(inMemory: true)
    }

    private func card(_ productId: Int, _ context: ModelContext) -> OwnedCard {
        let card = OwnedCard(productId: productId, printing: "Normal", condition: "Near Mint", confidence: .manual)
        context.insert(card)
        return card
    }

    /// Market prices by product id, in cents.
    private func market(_ prices: [Int: Int]) -> (OwnedCard) -> Int? {
        { prices[$0.productId] }
    }

    @Test @MainActor func aLooseCardTakesItsShareByMarket() throws {
        let container = try store()
        let context = container.mainContext
        let purchase = Purchase(vendor: "Card show", itemCostCents: 10_000)
        context.insert(purchase)
        let a = card(1, context)
        let b = card(2, context)

        let moved = try PurchaseLink.link([a, b], to: purchase, since: nil, marketCents: market([1: 3_000, 2: 1_000]), context: context)

        #expect(moved == 2)
        #expect(a.acquisitionBasisCents == 7_500)
        #expect(b.acquisitionBasisCents == 2_500)
        #expect(a.purchase?.id == purchase.id)
        #expect(purchase.items.count == 2)
    }

    /// The purchase the card left splits again over the cards that stay.
    @Test @MainActor func bothPurchasesSplitAgain() throws {
        let container = try store()
        let context = container.mainContext
        let old = Purchase(vendor: "Walmart", itemCostCents: 6_000)
        let new = Purchase(vendor: "Target", itemCostCents: 2_000)
        context.insert(old)
        context.insert(new)
        let prices = market([1: 1_000, 2: 1_000])
        let lines = [
            PurchaseIntake.Line(productId: 1, name: "A", setName: "S", isSealed: false),
            PurchaseIntake.Line(productId: 2, name: "B", setName: "S", isSealed: false),
        ]
        let cards = PurchaseIntake.record(lines, on: old, since: nil, marketCents: prices, context: context)
        #expect(cards.map(\.acquisitionBasisCents) == [3_000, 3_000])

        let lineOfMoved = cards[1].sourceItem
        try PurchaseLink.link([cards[1]], to: new, since: nil, marketCents: prices, context: context)

        #expect(cards[0].acquisitionBasisCents == 6_000)
        #expect(cards[1].acquisitionBasisCents == 2_000)
        // Alone on its line, the card moved with the line.
        #expect(cards[1].sourceItem === lineOfMoved)
        #expect(lineOfMoved?.purchase?.id == new.id)
    }

    /// One copy of three leaves. The line stays on the old purchase and lists
    /// two copies. No line is deleted.
    @Test @MainActor func oneCopyOfSeveralGetsItsOwnLine() throws {
        let container = try store()
        let context = container.mainContext
        let old = Purchase(vendor: "Walmart", itemCostCents: 9_000)
        let new = Purchase(vendor: "Target", itemCostCents: 4_000)
        context.insert(old)
        context.insert(new)
        let packs = PurchaseIntake.record(
            [PurchaseIntake.Line(productId: 5, name: "Pack", setName: "S", isSealed: true, quantity: 3)],
            on: old, since: nil, context: context
        )
        let oldLine = try #require(packs[0].sourceItem)

        try PurchaseLink.link([packs[0]], to: new, since: nil, context: context)

        #expect(oldLine.quantity == 2)
        #expect(oldLine.purchase?.id == old.id)
        #expect(oldLine.cards.count == 2)
        #expect(packs[0].sourceItem !== oldLine)
        #expect(packs[0].sourceItem?.isSealed == true)
        #expect(packs[0].acquisitionBasisCents == 4_000)
        #expect(packs[1].acquisitionBasisCents + packs[2].acquisitionBasisCents == 9_000)
    }

    @Test @MainActor func aTypedCostStaysAndComesOffTheTotal() throws {
        let container = try store()
        let context = container.mainContext
        let purchase = Purchase(vendor: "Card show", itemCostCents: 10_000)
        context.insert(purchase)
        let typed = card(1, context)
        typed.acquisitionBasisCents = 6_000
        typed.basisIsManual = true
        let other = card(2, context)

        try PurchaseLink.link([typed, other], to: purchase, since: nil, marketCents: market([1: 1_000, 2: 1_000]), context: context)

        #expect(typed.acquisitionBasisCents == 6_000)
        #expect(typed.basisIsManual)
        #expect(other.acquisitionBasisCents == 4_000)
    }

    /// A pull from a ripped pack shares the pack's line. It gets its own line,
    /// and the pack's line keeps its parent.
    @Test @MainActor func aPullGetsItsOwnLine() throws {
        let container = try store()
        let context = container.mainContext
        let purchase = Purchase(vendor: "Target", itemCostCents: 1_000)
        context.insert(purchase)
        let pack = PurchaseItem(productId: 9)
        context.insert(pack)
        let pull = card(3, context)
        pull.sourceItem = pack

        try PurchaseLink.link([pull], to: purchase, since: nil, context: context)

        #expect(pull.sourceItem !== pack)
        #expect(pull.purchase?.id == purchase.id)
        #expect(pack.purchase == nil)
        #expect(pull.acquisitionBasisCents == 1_000)
    }

    @Test @MainActor func aCardAlreadyOnThePurchaseDoesNotMove() throws {
        let container = try store()
        let context = container.mainContext
        let purchase = Purchase(vendor: "Target", itemCostCents: 1_000)
        context.insert(purchase)
        let cards = PurchaseIntake.record(
            [PurchaseIntake.Line(productId: 1, name: "A", setName: "S", isSealed: false)],
            on: purchase, since: nil, context: context
        )
        #expect(try PurchaseLink.link(cards, to: purchase, since: nil, context: context) == 0)
        #expect(purchase.items.count == 1)
    }
}
