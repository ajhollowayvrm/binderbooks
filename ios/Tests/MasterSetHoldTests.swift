import Foundation
import Testing
@testable import BinderBooks

@Suite struct MasterSetHoldTests {
    private typealias Export = TCGplayerListingExport

    let prices: [Int: [ProductPrice]] = [
        1: [ProductPrice(subTypeName: "Holofoil", marketCents: 200, asOf: "2026-09-21")],
        2: [ProductPrice(subTypeName: "Normal", marketCents: 10, asOf: "2026-09-21"),
            ProductPrice(subTypeName: "Reverse Holofoil", marketCents: 40, asOf: "2026-09-21")],
    ]

    // MARK: - The stored flag

    @Test func theFlagReadsAndWritesOneSetAtATime() {
        var stored = ""
        stored = MasterSetHold.text(stored, setting: 24_073, to: true)
        stored = MasterSetHold.text(stored, setting: 3_172, to: true)
        #expect(stored == "3172,24073")
        #expect(MasterSetHold.ids(stored) == [3_172, 24_073])

        stored = MasterSetHold.text(stored, setting: 3_172, to: false)
        #expect(stored == "24073")
        #expect(!MasterSetHold.ids(stored).contains(3_172))
        #expect(MasterSetHold.ids("") == [])
    }

    // MARK: - Which copy stays

    @Test @MainActor func theBestCopyOfEachPrintingStays() throws {
        let nearMint = card(1)
        let played = card(1, condition: "Lightly Played")
        let normal = card(2, printing: "Normal")
        let reverse = card(2, printing: "Reverse Holofoil")
        let rows = [played, nearMint, normal, reverse].map { InventoryRow(card: $0, hit: hit($0.productId)) }

        let held = MasterSetHold.keep(from: rows, prices: prices, groups: [1])
        // A reverse holo is its own slot, so both copies of product 2 stay.
        #expect(held == [nearMint.id, normal.id, reverse.id])
    }

    @Test @MainActor func anotherSetKeepsNothing() {
        let card = card(1)
        let rows = [InventoryRow(card: card, hit: hit(1, group: 99))]
        #expect(MasterSetHold.keep(from: rows, prices: prices, groups: [1]).isEmpty)
        #expect(MasterSetHold.keep(from: rows, prices: prices, groups: []).isEmpty)
    }

    /// A slab, a personal collection card, and a card at the grader never
    /// reach the file, so the slot they fill needs no copy held back.
    @Test @MainActor func acopyHeCannotListAlreadyFillsTheSlot() {
        let slab = card(1)
        slab.certNumber = "12345678"
        slab.graderRaw = "PSA"
        slab.gradeLabel = "10"
        let raw = card(1, condition: "Lightly Played")
        #expect(Export.skipReason(for: slab, hit: hit(1)) == .slab)

        let rows = [slab, raw].map { InventoryRow(card: $0, hit: hit($0.productId)) }
        #expect(MasterSetHold.keep(from: rows, prices: prices, groups: [1]).isEmpty)

        let personal = card(2, printing: "Normal")
        personal.isPersonalCollection = true
        let spare = card(2, printing: "Normal")
        let two = [personal, spare].map { InventoryRow(card: $0, hit: hit(2)) }
        #expect(MasterSetHold.keep(from: two, prices: prices, groups: [1]).isEmpty)
    }

    @Test @MainActor func asoldCopyFillsNothing() {
        let sold = card(1)
        sold.tags = [ReservedTag.sold]
        let spare = card(1)
        let rows = [sold, spare].map { InventoryRow(card: $0, hit: hit(1)) }
        #expect(MasterSetHold.keep(from: rows, prices: prices, groups: [1]) == [spare.id])
    }

    // MARK: - The file

    @Test @MainActor func abulkCardListsEveryCopyButOne() throws {
        let bulk = card(1)
        bulk.isBulk = true
        bulk.quantity = 12
        let rows = [InventoryRow(card: bulk, hit: hit(1))]

        let held = MasterSetHold.keep(from: rows, prices: prices, groups: [1])
        #expect(held == [bulk.id])

        let plan = Export.plan(rows, prices: prices, holdingOne: held)
        let line = try #require(plan.lines.first)
        #expect(line.quantity == 11)
        #expect(line.cardIds == [bulk.id])
    }

    @Test @MainActor func aheldCardWithOneCopyLeavesTheFileAndTakesNoTag() {
        let single = card(1)
        let rows = [InventoryRow(card: single, hit: hit(1))]

        let plan = Export.plan(rows, prices: prices, holdingOne: [single.id])
        #expect(plan.lines.isEmpty)
        #expect(plan.skipped.isEmpty)
    }

    // MARK: - Helpers

    private func hit(_ id: Int, group: Int = 1) -> SearchHit {
        SearchHit(productId: id, groupId: group, categoryId: TCGCategory.pokemon, name: "Card \(id)",
                  cleanName: "card \(id)", setName: "Set", isSealed: false, printingCount: 1)
    }

    @MainActor
    private func card(_ productId: Int, printing: String = "Holofoil", condition: String = "Near Mint") -> OwnedCard {
        OwnedCard(productId: productId, printing: printing, condition: condition, confidence: .manual)
    }
}
