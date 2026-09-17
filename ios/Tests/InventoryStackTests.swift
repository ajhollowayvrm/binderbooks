import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// Copies of one thing are one line on the page. Nine packs off one purchase
/// are nine cards in the store and one cell with "×9" on it.
@Suite struct InventoryStackTests {
    let container: ModelContainer

    init() throws {
        container = try CollectionStore.container(inMemory: true)
    }

    private func hit(_ id: Int, sealed: Bool = false) -> SearchHit {
        SearchHit(
            productId: id, groupId: 100, categoryId: 3, name: "P\(id)", cleanName: "p\(id)",
            setName: "SV10: Destined Rivals", isSealed: sealed, printingCount: 1
        )
    }

    private func inventory(_ prices: [Int: [ProductPrice]] = [:], hits: [Int] = [1]) -> InventoryModel {
        let model = InventoryModel()
        var rows: [Int: SearchHit] = [:]
        for id in hits { rows[id] = hit(id, sealed: true) }
        model.setTestRows(hits: rows, prices: prices)
        return model
    }

    /// Cards, newest last so the page's order is the order they were made in.
    @discardableResult
    private func packs(_ count: Int, basisCents: Int = 0, productId: Int = 1) -> [OwnedCard] {
        var made: [OwnedCard] = []
        for i in 0..<count {
            let card = OwnedCard(productId: productId, printing: "", condition: CardCondition.nearMint.rawValue, confidence: .manual)
            card.isSealedSelf = true
            card.acquisitionBasisCents = basisCents
            card.scannedAt = Date(timeIntervalSinceReferenceDate: 800_000_000 - Double(i))
            card.acquiredAt = card.scannedAt
            container.mainContext.insert(card)
            made.append(card)
        }
        return made
    }

    private func fetch() throws -> [OwnedCard] {
        try container.mainContext.fetch(FetchDescriptor<OwnedCard>())
    }

    @Test @MainActor func nineIdenticalPacksAreOneLineWithACount() throws {
        packs(9, basisCents: 800)
        try container.mainContext.save()
        let model = inventory([1: [ProductPrice(subTypeName: "", marketCents: 911, asOf: "2026-09-17")]])
        let cards = try fetch()

        // The rows stay per card: the sort, the chips and Metrics read cards.
        #expect(model.rows(from: cards).count == 9)

        let stacks = model.stacks(from: cards)
        #expect(stacks.count == 1)
        let stack = try #require(stacks.first)
        #expect(stack.copies == 9)
        #expect(stack.isStacked)
        #expect(stack.cardIds.count == 9)
        // The price stays the price of one — the list sorted by it — and the
        // stack carries the total beside it.
        #expect(stack.lead.marketCents == 911)
        #expect(stack.totalValueCents == 911 * 9)
        #expect(stack.totalBasisCents == 800 * 9)
        #expect(stack.unrealizedCents == (911 - 800) * 9)
        #expect(stack.route == .cardStack(stack.lead.card.id))
    }

    /// A stack is only cards that would draw the same cell. Anything the cell
    /// shows splits them.
    @Test @MainActor func aDifferenceSplitsTheLine() throws {
        let made = packs(4)
        made[1].condition = CardCondition.lightlyPlayed.rawValue
        made[2].tags = ["binder 3"]
        made[3].certNumber = "12345678"
        try container.mainContext.save()

        let stacks = inventory().stacks(from: try fetch())
        #expect(stacks.count == 4)
        #expect(stacks.allSatisfy { !$0.isStacked })
    }

    /// Case and inner space fold in a label, the same as everywhere else, so
    /// "Binder 3" and "binder  3" are one line.
    @Test @MainActor func labelsCompareTheWayTagsDo() throws {
        let made = packs(2)
        made[0].tags = ["Binder 3"]
        made[1].tags = ["binder  3"]
        try container.mainContext.save()

        #expect(inventory().stacks(from: try fetch()).count == 1)
    }

    /// A stack sits where its first copy sorted, so a sort or a filter reads
    /// the same with stacking as without it.
    @Test @MainActor func aStackSitsWhereItsFirstCopySorted() throws {
        packs(2, productId: 1)
        let later = packs(1, productId: 2)
        later[0].scannedAt = Date(timeIntervalSinceReferenceDate: 900_000_000)
        later[0].acquiredAt = later[0].scannedAt
        try container.mainContext.save()

        let model = inventory(hits: [1, 2])
        let stacks = model.stacks(from: try fetch())
        #expect(stacks.map(\.lead.card.productId) == [2, 1])
        #expect(stacks.map(\.copies) == [1, 2])
    }

    /// A bulk line of 40 is one card. It counts 40 copies, the same figure the
    /// row showed before stacking existed, and a tap opens that card.
    @Test @MainActor func aBulkLineIsOneCardWithManyCopies() throws {
        let made = packs(1)
        made[0].isBulk = true
        made[0].quantity = 40
        try container.mainContext.save()

        let stack = try #require(inventory().stacks(from: try fetch()).first)
        #expect(stack.copies == 40)
        #expect(!stack.isStacked)
        #expect(stack.route == .ownedCard(made[0].id))
    }

    /// The stack screen derives its copies again from the live rows, so a copy
    /// sold or deleted while it is open drops out of it.
    @Test @MainActor func theCopiesAreDerivedFromTheLiveRows() throws {
        let made = packs(3)
        try container.mainContext.save()
        let model = inventory()

        // The ids are read before the delete: a deleted model object is not
        // safe to touch afterwards.
        let goneID = made[0].id
        let keptID = made[1].id

        var rows = model.rows(from: try fetch())
        let stack = try #require(InventoryStack.stack(of: goneID, in: rows))
        #expect(stack.copies == 3)

        container.mainContext.delete(made[0])
        try container.mainContext.save()
        rows = model.rows(from: try fetch())
        #expect(InventoryStack.stack(of: goneID, in: rows) == nil)
        #expect(InventoryStack.stack(of: keptID, in: rows)?.copies == 2)
    }
}
