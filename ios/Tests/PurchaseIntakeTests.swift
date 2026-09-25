import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// A purchase recorded by hand can name what came in it, from the catalog.
/// These cover the list, the note it writes, and the cards it adds.
@Suite struct PurchaseIntakeTests {
    @MainActor private func store() throws -> ModelContainer {
        try CollectionStore.container(inMemory: true)
    }

    private let bought = Date(timeIntervalSince1970: 1_780_000_000)

    private func hit(_ productId: Int, _ name: String, sealed: Bool = false) -> SearchHit {
        SearchHit(productId: productId, groupId: 1, categoryId: 3, name: name, cleanName: name, setName: "Chaos Rising", isSealed: sealed, printingCount: 1)
    }

    @Test func aSecondTapAddsACopyAndNotARow() {
        let pack = hit(10, "Chaos Rising Booster Pack", sealed: true)
        var lines = PurchaseIntake.adding(pack, printings: ["Normal"], to: [])
        lines = PurchaseIntake.adding(pack, printings: [], to: lines)
        lines = PurchaseIntake.adding(hit(20, "Charizard ex"), printings: ["Holofoil", "Reverse Holofoil"], to: lines)

        #expect(lines.count == 2)
        #expect(lines[0].quantity == 2)
        #expect(lines[0].printing == "Normal")
        #expect(lines[1].printing == "Holofoil")
        #expect(PurchaseIntake.note(for: lines) == "2x Chaos Rising Booster Pack, Charizard ex")
    }

    /// The items go on the purchase, and the cards go into inventory linked
    /// to their lines. The landed $27.65 splits by market price: two $5 packs
    /// and a $15 Charizard take 20%, 20%, and 60%.
    @Test @MainActor func aPurchaseRecordsItsItemsAndSplitsItsCostByMarket() throws {
        let container = try store()
        let context = container.mainContext
        let purchase = Purchase(date: bought, vendor: "Whatnot", itemCostCents: 2_500, shippingCents: 78, taxCents: 187)
        context.insert(purchase)

        var lines = PurchaseIntake.adding(hit(10, "Chaos Rising Booster Pack", sealed: true), printings: ["Normal"], to: [])
        lines[0].quantity = 2
        lines = PurchaseIntake.adding(hit(20, "Charizard ex"), printings: ["Holofoil"], to: lines)

        let market = [10: 500, 20: 1_500]
        let cards = PurchaseIntake.record(lines, on: purchase, since: nil, marketCents: { market[$0.productId] }, context: context)
        try context.save()

        #expect(cards.count == 3)
        #expect(purchase.items.count == 2)
        #expect(purchase.items.reduce(0) { $0 + $1.quantity } == 3)
        #expect(purchase.landedCostCents == 2_765)
        #expect(cards.allSatisfy { $0.sourceItem != nil && $0.basisIsAllocated && $0.acquiredAt == bought })
        #expect(cards.reduce(0) { $0 + $1.acquisitionBasisCents } == 2_765)
        #expect(purchase.items.reduce(0) { $0 + $1.allocatedCostCents } == 2_765)

        let packs = cards.filter { $0.productId == 10 }
        #expect(packs.count == 2)
        #expect(packs.map(\.acquisitionBasisCents) == [553, 553])
        #expect(packs.filter { $0.isSealedSelf }.count == 2)

        let single = try #require(cards.first { $0.productId == 20 })
        #expect(!single.isSealedSelf)
        #expect(single.printing == "Holofoil")
        #expect(single.acquisitionBasisCents == 1_659)
    }

    /// A purchase dated before the books start is off the books, so its cards
    /// cost $0.
    @Test @MainActor func aPurchaseBeforeTheStartPutsNoCostOnItsCards() throws {
        let container = try store()
        let context = container.mainContext
        let purchase = Purchase(date: bought, vendor: "Walmart", itemCostCents: 1_000)
        context.insert(purchase)
        let lines = PurchaseIntake.adding(hit(20, "Charizard ex"), printings: ["Holofoil"], to: [])

        let cards = PurchaseIntake.record(lines, on: purchase, since: bought.addingTimeInterval(1), context: context)

        #expect(cards.count == 1)
        #expect(cards[0].acquisitionBasisCents == 0)
        #expect(cards[0].sourceItem != nil)
    }
}
