import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// A store with one purchase, two lines, three cards, and a committed session.
@MainActor
private func seed(_ context: ModelContext) throws {
    let purchase = Purchase(date: Date(timeIntervalSinceReferenceDate: 800_000_000.123), vendor: "Whatnot", note: "slab lot", itemCostCents: 5_700)
    purchase.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    context.insert(purchase)

    let session = ScanSession(defaultCondition: "Lightly Played", defaultPrinting: "Reverse Holofoil")
    session.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    session.committedAt = Date(timeIntervalSinceReferenceDate: 800_000_100.5)
    session.purchase = purchase
    session.observedGroupIds = [100, 101]
    context.insert(session)

    let line1 = PurchaseItem(productId: 1)
    line1.id = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    line1.purchase = purchase
    context.insert(line1)
    let line2 = PurchaseItem(productId: 2, quantity: 1, isSealed: false)
    line2.id = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    line2.purchase = purchase
    line2.parentItem = line1
    context.insert(line2)

    let slab = OwnedCard(productId: 1, printing: "Holofoil", condition: "Near Mint", confidence: .manual)
    slab.id = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    slab.acquisitionBasisCents = 4_100
    slab.certNumber = "12345678"
    slab.graderRaw = "psa"
    slab.sourceItem = line1
    slab.scanSession = session
    context.insert(slab)

    let pull = OwnedCard(productId: 2, printing: "Normal", condition: "Lightly Played", confidence: .uncertain)
    pull.id = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
    pull.acquisitionBasisCents = 1_600
    pull.basisIsAllocated = true
    pull.candidateProductIds = [2, 7]
    pull.ocrName = "Charizard"
    pull.ocrNumber = "4/102"
    pull.sourceItem = line2
    pull.scanSession = session
    context.insert(pull)

    let bulk = OwnedCard(productId: 3, printing: "Normal", condition: "Near Mint", confidence: .certain)
    bulk.id = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
    bulk.isBulk = true
    bulk.quantity = 4
    bulk.sourceItem = line2
    bulk.scanSession = session
    context.insert(bulk)

    try context.save()
}

@Suite struct CollectionExportTests {
    let source: ModelContainer
    let target: ModelContainer

    init() throws {
        source = try CollectionStore.container(inMemory: true)
        target = try CollectionStore.container(inMemory: true)
    }

    @Test @MainActor func roundTripsExactly() throws {
        try seed(source.mainContext)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_200)

        let first = try CollectionExport.exportData(source.mainContext, now: now)
        let file = try CollectionExport.decode(first)
        #expect(file.purchases.count == 1)
        #expect(file.purchaseItems.count == 2)
        #expect(file.cards.count == 3)
        #expect(file.sessions.count == 1)

        let report = try CollectionExport.apply(file, to: target.mainContext, mode: .merge)
        #expect(report == CollectionExport.Report(purchases: 1, purchaseItems: 2, cards: 3, sessions: 1, deleted: 0))

        let second = try CollectionExport.exportData(target.mainContext, now: now)
        #expect(first == second)

        // Relationships survived by id.
        let cards = try target.mainContext.fetch(FetchDescriptor<OwnedCard>())
        let pull = try #require(cards.first { $0.productId == 2 })
        #expect(pull.sourceItem?.parentItem?.productId == 1)
        #expect(pull.scanSession?.purchase?.vendor == "Whatnot")
        #expect(pull.basisIsAllocated)
        #expect(pull.candidateProductIds == [2, 7])
        #expect(pull.isCommitted)
    }

    @Test @MainActor func importIsIdempotent() throws {
        try seed(source.mainContext)
        let file = try CollectionExport.snapshot(source.mainContext)
        try CollectionExport.apply(file, to: target.mainContext, mode: .merge)
        try CollectionExport.apply(file, to: target.mainContext, mode: .merge)
        #expect(try target.mainContext.fetch(FetchDescriptor<OwnedCard>()).count == 3)
        #expect(try target.mainContext.fetch(FetchDescriptor<PurchaseItem>()).count == 2)
        #expect(try target.mainContext.fetch(FetchDescriptor<Purchase>()).count == 1)
    }

    @Test @MainActor func replaceDeletesWhatTheFileLacks() throws {
        try seed(source.mainContext)
        let stray = Purchase(vendor: "Stray", itemCostCents: 1)
        target.mainContext.insert(stray)
        try target.mainContext.save()

        let file = try CollectionExport.snapshot(source.mainContext)
        let merged = try CollectionExport.apply(file, to: target.mainContext, mode: .merge)
        #expect(merged.deleted == 0)
        #expect(try target.mainContext.fetch(FetchDescriptor<Purchase>()).count == 2)

        let replaced = try CollectionExport.apply(file, to: target.mainContext, mode: .replace)
        #expect(replaced.deleted > 0)
        #expect(try target.mainContext.fetch(FetchDescriptor<Purchase>()).map(\.vendor) == ["Whatnot"])
    }

    @Test func rejectsOtherFilesAndNewerVersions() {
        #expect(throws: (any Error).self) {
            try CollectionExport.decode(Data("{\"buys\":[]}".utf8))
        }
        let newer = "{\"format\":\"cardtracker-collection\",\"version\":99,\"exportedAt\":\"x\",\"purchases\":[],\"purchaseItems\":[],\"cards\":[],\"sessions\":[]}"
        #expect(throws: CollectionExport.ImportError.self) {
            try CollectionExport.decode(Data(newer.utf8))
        }
    }

    @Test func exportIsDeterministic() throws {
        let file = CollectionExport.File(exportedAt: "2026-09-10T05:00:00Z", purchases: [], purchaseItems: [], cards: [], sessions: [])
        #expect(try CollectionExport.encode(file) == CollectionExport.encode(file))
        let text = try #require(String(data: CollectionExport.encode(file), encoding: .utf8))
        #expect(text.contains("\"format\" : \"cardtracker-collection\""))
    }
}

@Suite struct InventoryModelTests {
    let container: ModelContainer

    init() throws {
        container = try CollectionStore.container(inMemory: true)
    }

    private func hit(_ id: Int, group: Int) -> SearchHit {
        SearchHit(productId: id, groupId: group, categoryId: 3, name: "P\(id)", cleanName: "p\(id)", setName: "Set \(group)", isSealed: false, printingCount: 1)
    }

    @Test @MainActor func summaryKeepsAllocatedBasisOutOfUnrealized() throws {
        try seed(container.mainContext)
        let model = InventoryModel()
        model.setTestRows(
            hits: [1: hit(1, group: 100), 2: hit(2, group: 101), 3: hit(3, group: 101)],
            prices: [
                1: [ProductPrice(subTypeName: "Holofoil", marketCents: 8_103, lowCents: nil, midCents: nil, highCents: nil, directLowCents: nil, asOf: "2026-09-10")],
                2: [ProductPrice(subTypeName: "Normal", marketCents: 197, lowCents: nil, midCents: nil, highCents: nil, directLowCents: nil, asOf: "2026-09-10")],
                3: [ProductPrice(subTypeName: "Normal", marketCents: 5, lowCents: nil, midCents: nil, highCents: nil, directLowCents: nil, asOf: "2026-09-10")],
            ]
        )
        let cards = try container.mainContext.fetch(FetchDescriptor<OwnedCard>())
        let rows = model.rows(from: cards)
        #expect(rows.count == 3)

        let summary = model.summary(of: rows)
        #expect(summary.cardCount == 6)
        #expect(summary.marketCents == 8_103 + 197 + 5 * 4)
        #expect(summary.basisCents == 4_100 + 1_600)
        #expect(summary.pricedBasisCents == 4_100)
        #expect(summary.pricedMarketCents == 8_103)
        #expect(summary.unrealizedCents == 4_003)
        #expect(summary.allocatedCount == 1)

        let pull = try #require(rows.first { $0.card.productId == 2 })
        #expect(pull.unrealizedCents == nil)
        let slab = try #require(rows.first { $0.card.productId == 1 })
        #expect(slab.unrealizedCents == 4_003)
    }

    @Test @MainActor func filtersNarrow() throws {
        try seed(container.mainContext)
        let model = InventoryModel()
        model.setTestRows(hits: [1: hit(1, group: 100), 2: hit(2, group: 101), 3: hit(3, group: 101)], prices: [:])
        let cards = try container.mainContext.fetch(FetchDescriptor<OwnedCard>())

        model.filter.slabsOnly = true
        #expect(model.rows(from: cards).map(\.card.productId) == [1])

        model.filter = InventoryFilter(groupId: 101)
        #expect(Set(model.rows(from: cards).map(\.card.productId)) == [2, 3])

        model.filter = InventoryFilter(confidences: [.uncertain])
        #expect(model.rows(from: cards).map(\.card.productId) == [2])

        model.filter = InventoryFilter(hideBulk: true)
        #expect(Set(model.rows(from: cards).map(\.card.productId)) == [1, 2])
    }

    @Test @MainActor func uncommittedCardsStayOut() throws {
        try seed(container.mainContext)
        let open = ScanSession()
        container.mainContext.insert(open)
        let card = OwnedCard(productId: 9, printing: "Normal", condition: "Near Mint", confidence: .certain)
        card.scanSession = open
        container.mainContext.insert(card)
        try container.mainContext.save()

        let model = InventoryModel()
        let cards = try container.mainContext.fetch(FetchDescriptor<OwnedCard>())
        #expect(cards.count == 4)
        #expect(model.rows(from: cards).count == 3)
    }
}
