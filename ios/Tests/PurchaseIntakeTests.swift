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

    /// The items go on the purchase. The cards go into inventory with no link
    /// to it and no cost, and the landed total stays $27.65.
    @Test @MainActor func aPurchaseRecordsItsItemsAndTheCardsStandAlone() throws {
        let container = try store()
        let context = container.mainContext
        let purchase = Purchase(date: bought, vendor: "Whatnot", itemCostCents: 2_500, shippingCents: 78, taxCents: 187)
        context.insert(purchase)

        var lines = PurchaseIntake.adding(hit(10, "Chaos Rising Booster Pack", sealed: true), printings: ["Normal"], to: [])
        lines[0].quantity = 2
        lines = PurchaseIntake.adding(hit(20, "Charizard ex"), printings: ["Holofoil"], to: lines)

        let cards = PurchaseIntake.record(lines, on: purchase, context: context)
        try context.save()

        #expect(cards.count == 3)
        #expect(purchase.items.count == 2)
        #expect(purchase.items.reduce(0) { $0 + $1.quantity } == 3)
        #expect(purchase.landedCostCents == 2_765)
        #expect(cards.allSatisfy { $0.sourceItem == nil && $0.acquisitionBasisCents == 0 && $0.acquiredAt == bought })
        #expect(purchase.items.allSatisfy { $0.cards.isEmpty && $0.allocatedCostCents == 0 })

        let packs = cards.filter { $0.productId == 10 }
        #expect(packs.count == 2)
        #expect(packs.filter { $0.isSealedSelf }.count == 2)

        let single = try #require(cards.first { $0.productId == 20 })
        #expect(!single.isSealedSelf)
        #expect(single.printing == "Holofoil")
    }
}
