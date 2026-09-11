import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// A store with one purchase, two lines, three cards, a committed session, a
/// grading submission, and a sale with two lines.
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
    slab.tags = ["PSA queue", "binder 3"]
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
    pull.tags = ["for sale"]
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

    // The sealed line is the pack. There is no rip row.
    line1.isSealed = true
    line1.isRipped = true
    pull.gradedCompCents = ["10": 12_000, "9.5": 5_100]

    let submission = GradingSubmission(graderRaw: "psa", shippedAt: Date(timeIntervalSinceReferenceDate: 800_000_060), gradingFeesCents: 26_897)
    submission.id = UUID(uuidString: "00000000-0000-0000-0000-000000000009")!
    submission.sourceRef = "sub1"
    context.insert(submission)

    let entry = GradingEntry(submission: submission, card: slab)
    entry.id = UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!
    entry.grade = 9.5
    entry.certNumber = "12345678"
    entry.allocatedFeeCents = 26_897
    context.insert(entry)

    let sale = Sale(soldAt: Date(timeIntervalSinceReferenceDate: 800_000_070), channelRaw: "tcgplayer", grossCents: 1_515)
    sale.id = UUID(uuidString: "00000000-0000-0000-0000-00000000000b")!
    sale.marketplaceFeesCents = 232
    sale.sourceRef = "z9kftlmj"
    context.insert(sale)

    let soldLine = SaleLine(sale: sale, card: pull, basisCents: 1_600)
    soldLine.id = UUID(uuidString: "00000000-0000-0000-0000-00000000000c")!
    soldLine.describedAs = "Charizard"
    context.insert(soldLine)

    // The older orders record a price and no card. Revenue is real; cost is not there.
    let unknownLine = SaleLine(sale: sale, card: nil, basisCents: 0, basisIncomplete: true)
    unknownLine.id = UUID(uuidString: "00000000-0000-0000-0000-00000000000d")!
    unknownLine.describedAs = "Poke Pad"
    context.insert(unknownLine)

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
        #expect(file.grading?.count == 1)
        #expect(file.gradingEntries?.count == 1)
        #expect(file.sales?.count == 1)
        #expect(file.saleLines?.count == 2)

        let report = try CollectionExport.apply(file, to: target.mainContext, mode: .merge)
        #expect(report == CollectionExport.Report(
            purchases: 1, purchaseItems: 2, cards: 3, sessions: 1,
            grading: 1, gradingEntries: 1, sales: 1, saleLines: 2, deleted: 0
        ))

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
        #expect(pull.sourceItem?.parentItem?.isRipped == true)
        #expect(pull.gradedCompCents == ["10": 12_000, "9.5": 5_100])

        let sale = try #require(try target.mainContext.fetch(FetchDescriptor<Sale>()).first)
        #expect(sale.lines.count == 2)
        #expect(sale.netCents == 1_283)
        // One line has no known cost, so the sale reports no gain rather than
        // a gain of the whole price.
        #expect(sale.realizedGainCents == nil)
        #expect(sale.lines.contains { $0.card?.productId == 2 })

        let submission = try #require(try target.mainContext.fetch(FetchDescriptor<GradingSubmission>()).first)
        #expect(submission.entries.first?.card?.certNumber == "12345678")
        #expect(submission.totalCostCents == 26_897)
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

    /// The one test that guards every backup he already has. A non-optional
    /// `tags` field in the DTO would throw `keyNotFound` on all of them.
    @Test @MainActor func importsAVersionOneFileWithNoTagsKey() throws {
        let json = """
        {"format":"cardtracker-collection","version":1,"exportedAt":"2026-01-01T00:00:00Z",
         "purchases":[],"purchaseItems":[],"sessions":[],
         "cards":[{"id":"00000000-0000-0000-0000-0000000000AA","productId":7,"printing":"Normal",
           "condition":"Near Mint","language":"en","quantity":1,"acquiredAt":800000000,
           "statusRaw":"owned","acquisitionBasisCents":100,"gradingBasisCents":0,
           "basisIsAllocated":false,"isBulk":false,"isPersonalCollection":false,
           "matchConfidenceRaw":"manual","candidateProductIds":[],"scannedAt":800000000}]}
        """
        let file = try CollectionExport.decode(Data(json.utf8))
        #expect(file.cards.first?.tags == nil)
        _ = try CollectionExport.apply(file, to: target.mainContext, mode: .merge)
        let card = try #require(try target.mainContext.fetch(FetchDescriptor<OwnedCard>()).first)
        #expect(card.tags == [])
    }

    /// An expense is money that attaches to no card, so nothing else in the
    /// file points at it. It still has to survive the only backup he has.
    @Test @MainActor func anExpenseSurvivesTheRoundTrip() throws {
        let expense = BusinessExpense(
            date: Date(timeIntervalSinceReferenceDate: 800_000_000),
            category: "Supplies", vendor: "Amazon", amountCents: 2_499, note: "500 penny sleeves"
        )
        source.mainContext.insert(expense)
        try source.mainContext.save()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_200)

        let first = try CollectionExport.exportData(source.mainContext, now: now)
        let file = try CollectionExport.decode(first)
        #expect(file.expenses?.count == 1)

        let report = try CollectionExport.apply(file, to: target.mainContext, mode: .merge)
        #expect(report.expenses == 1)

        let restored = try #require(try target.mainContext.fetch(FetchDescriptor<BusinessExpense>()).first)
        #expect(restored.id == expense.id)
        #expect(restored.category == "Supplies")
        #expect(restored.vendor == "Amazon")
        #expect(restored.amountCents == 2_499)
        #expect(restored.note == "500 penny sleeves")

        #expect(try CollectionExport.exportData(target.mainContext, now: now) == first)
    }

    /// Every backup he already holds is version 4 and carries no `expenses`
    /// key. A non-optional field in `File` would throw `keyNotFound` on all of
    /// them, the same way a non-optional `tags` would have.
    @Test @MainActor func importsAVersionFourFileWithNoExpensesKey() throws {
        let json = """
        {"format":"cardtracker-collection","version":4,"exportedAt":"2026-01-01T00:00:00Z",
         "purchases":[],"purchaseItems":[],"sessions":[],"cards":[]}
        """
        let file = try CollectionExport.decode(Data(json.utf8))
        #expect(file.expenses == nil)
        let report = try CollectionExport.apply(file, to: target.mainContext, mode: .merge)
        #expect(report.expenses == 0)
        #expect(try target.mainContext.fetch(FetchDescriptor<BusinessExpense>()).isEmpty)
    }

    /// A sealed self-card and the rip session pointed at its own line, since
    /// `isSealedSelf` and `ripTarget` are the newest fields in the file.
    @Test @MainActor func aSealedSelfCardAndItsRipTargetSurviveTheRoundTrip() throws {
        let purchase = Purchase(vendor: "Walmart", itemCostCents: 4_997)
        source.mainContext.insert(purchase)
        let box = PurchaseItem(productId: 55, quantity: 1, isSealed: true)
        box.purchase = purchase
        box.allocatedCostCents = 4_997
        source.mainContext.insert(box)
        let selfCard = OwnedCard(productId: 55, printing: "", condition: "Near Mint", confidence: .manual)
        selfCard.isSealedSelf = true
        selfCard.sourceItem = box
        source.mainContext.insert(selfCard)
        let session = ScanSession()
        session.purchase = purchase
        session.ripTarget = box
        source.mainContext.insert(session)
        try source.mainContext.save()

        let file = try CollectionExport.snapshot(source.mainContext)
        #expect(file.cards.first { $0.productId == 55 }?.isSealedSelf == true)
        #expect(file.sessions.first?.ripTargetId == box.id)

        _ = try CollectionExport.apply(file, to: target.mainContext, mode: .merge)
        let restoredCard = try #require(try target.mainContext.fetch(FetchDescriptor<OwnedCard>()).first { $0.productId == 55 })
        #expect(restoredCard.isSealedSelf)
        let restoredSession = try #require(try target.mainContext.fetch(FetchDescriptor<ScanSession>()).first)
        #expect(restoredSession.ripTarget?.productId == 55)
    }

    @Test func exportIsDeterministic() throws {
        let file = CollectionExport.File(exportedAt: "2026-09-10T05:00:00Z", purchases: [], purchaseItems: [], cards: [], sessions: [])
        #expect(try CollectionExport.encode(file) == CollectionExport.encode(file))
        let text = try #require(String(data: CollectionExport.encode(file), encoding: .utf8))
        #expect(text.contains("\"format\" : \"cardtracker-collection\""))
    }
}

/// The real BinderBooks ledger, converted by scripts/import_binderbooks.py.
///
/// The file in `seed/` is what he actually imports, so these numbers are the
/// ones on his books. They come from docs/04-seed-import.md. A converter or an
/// importer that loses money fails here and nowhere else.
@Suite struct SeedLedgerImportTests {
    static let file: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // ios
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("seed/binderbooks-collection.json")

    private func load() throws -> CollectionExport.File {
        try CollectionExport.decode(try Data(contentsOf: Self.file))
    }

    @Test @MainActor func theLedgerImportsAndTheMoneyReconciles() throws {
        let file = try load()
        let store = try CollectionStore.container(inMemory: true)
        let report = try CollectionExport.apply(file, to: store.mainContext, mode: .replace)

        #expect(report.purchases == 93)
        #expect(report.grading == 8)
        #expect(report.purchaseItems == 58)
        #expect(report.sales == 131)
        #expect(report.saleLines == 210)

        let context = store.mainContext
        let purchases = try context.fetch(FetchDescriptor<Purchase>())
        #expect(purchases.reduce(0) { $0 + $1.itemCostCents } == 1_128_302)

        let grading = try context.fetch(FetchDescriptor<GradingSubmission>())
        #expect(grading.reduce(0) { $0 + $1.gradingFeesCents } == 175_288)

        let sales = try context.fetch(FetchDescriptor<Sale>())
        #expect(sales.reduce(0) { $0 + $1.grossCents } == 355_159)
        #expect(sales.reduce(0) { $0 + $1.netCents } == 292_210)

        // docs/04 records this as byMarketValue, because that is what happened.
        // Re-allocating would change the basis on cards that have already sold.
        #expect(purchases.allSatisfy { $0.allocationMethod == .byMarketValue })
    }

    @Test @MainActor func importingTheLedgerTwiceChangesNothing() throws {
        let file = try load()
        let store = try CollectionStore.container(inMemory: true)
        try CollectionExport.apply(file, to: store.mainContext, mode: .merge)
        let first = try CollectionExport.exportData(store.mainContext, now: Date(timeIntervalSinceReferenceDate: 0))
        try CollectionExport.apply(file, to: store.mainContext, mode: .merge)
        let second = try CollectionExport.exportData(store.mainContext, now: Date(timeIntervalSinceReferenceDate: 0))

        // The converter derives every id from the BinderBooks id, so a second
        // run upserts the same rows instead of doubling the ledger.
        #expect(first == second)
        #expect(try store.mainContext.fetch(FetchDescriptor<Sale>()).count == 131)
    }

    @Test @MainActor func aCardHeIsGradingKeepsItsCostAndItsComps() throws {
        let file = try load()
        let store = try CollectionStore.container(inMemory: true)
        try CollectionExport.apply(file, to: store.mainContext, mode: .replace)
        let cards = try store.mainContext.fetch(FetchDescriptor<OwnedCard>())

        // A card at a named grader carries that grader's own label, so its
        // price can show as a range. Every at-grader row in this ledger names
        // PSA or CGC; none falls back to the generic "at grader" label.
        let atGrader = cards.filter { $0.tags.contains("at PSA") || $0.tags.contains("at CGC") || $0.tags.contains("at grader") }
        #expect(atGrader.count == 40)
        #expect(atGrader.allSatisfy { $0.graderRaw != nil })
        // Nine carry no per-card fee: the outstanding May 2026 PSA submission
        // that docs/00 names. Its two charges sit in `buys` and were never
        // spread over the cards, so the cost is on the submission, not here.
        #expect(atGrader.filter { $0.gradingBasisCents > 0 }.count == 31)
        // docs/04: the 8 charges name a card count and no cards, so nothing
        // joins them. Each card carries its own grading cost instead.
        #expect(try store.mainContext.fetch(FetchDescriptor<GradingEntry>()).isEmpty)

        let withComps = cards.filter { !$0.gradedCompCents.isEmpty }
        #expect(withComps.count == 33)
        // A card at a named grader gets a real range immediately, because its
        // speculative grades now carry that grader's own prefix.
        let projectable = cards.filter { GradedComps.graderAtGrader(tags: $0.tags) != nil && GradedComps.range(for: GradedComps.graderAtGrader(tags: $0.tags)!, in: $0.gradedCompCents) != nil }
        #expect(projectable.count == 33)

        // A card that came back graded carries the grade it was returned at,
        // reordered to the app's own "word before number" convention.
        let returned = cards.filter { $0.tags.contains("graded") }
        #expect(returned.count == 35)
        #expect(returned.allSatisfy { $0.gradeLabel != nil })
        #expect(returned.filter { $0.gradeLabel == "Pristine 10" }.count == 14)
    }

    @Test @MainActor func kePtIsADefaultAndNeverMeansPersonalCollection() throws {
        let file = try load()
        let store = try CollectionStore.container(inMemory: true)
        try CollectionExport.apply(file, to: store.mainContext, mode: .replace)
        let cards = try store.mainContext.fetch(FetchDescriptor<OwnedCard>())

        #expect(cards.allSatisfy { !$0.isPersonalCollection })
        #expect(cards.contains { $0.tags.contains("sold") })
        #expect(cards.allSatisfy { !$0.tags.contains("kept") })
    }

    @Test @MainActor func aRipPullSaysItsCostWasDerived() throws {
        let file = try load()
        let store = try CollectionStore.container(inMemory: true)
        try CollectionExport.apply(file, to: store.mainContext, mode: .replace)
        let cards = try store.mainContext.fetch(FetchDescriptor<OwnedCard>())

        // The sealed line is the pack. There is no rip row to point at.
        let pulls = cards.filter { $0.sourceItem?.isSealed == true }
        #expect(pulls.count > 200)
        #expect(pulls.allSatisfy { $0.sourceItem?.isRipped == true })
        #expect(pulls.allSatisfy { $0.sourceItem?.purchase != nil })

        // docs/04: the $193 box that produced three near-worthless hits. The
        // basis is allocated, and the card says so.
        let allocated = cards.filter(\.basisIsAllocated)
        #expect(allocated.allSatisfy { !$0.basisIsManual })
        // The Whatnot slabs he priced himself are the other case.
        let typed = cards.filter(\.basisIsManual)
        #expect(!typed.isEmpty)
        #expect(typed.allSatisfy { !$0.basisIsAllocated })
    }

    @Test @MainActor func aSaleWithNoKnownCostReportsNoGain() throws {
        let file = try load()
        let store = try CollectionStore.container(inMemory: true)
        try CollectionExport.apply(file, to: store.mainContext, mode: .replace)
        let sales = try store.mainContext.fetch(FetchDescriptor<Sale>())

        // 35 orders carry a price and no line at all, and many lines carry no
        // basis. Revenue is real either way; a 100% margin would not be.
        let unknown = sales.filter { $0.realizedGainCents == nil }
        #expect(unknown.count >= 35)
        #expect(sales.allSatisfy { $0.externalOrderId.isEmpty })
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

    /// A cost split out of a purchase is still the figure he sells against, so
    /// it counts towards unrealized. `allocatedCount` reports how many were
    /// split; it no longer removes them (his call, 2026-09-10).
    @Test @MainActor func unrealizedCoversEveryCardWithACostAndAPrice() throws {
        try seed(container.mainContext)
        let model = InventoryModel()
        model.setTestRows(
            hits: [1: hit(1, group: 100), 2: hit(2, group: 101), 3: hit(3, group: 101)],
            prices: [
                1: [ProductPrice(subTypeName: "Holofoil", marketCents: 8_103, asOf: "2026-09-10")],
                2: [ProductPrice(subTypeName: "Normal", marketCents: 197, asOf: "2026-09-10")],
                3: [ProductPrice(subTypeName: "Normal", marketCents: 5, asOf: "2026-09-10")],
            ]
        )
        let cards = try container.mainContext.fetch(FetchDescriptor<OwnedCard>())
        let rows = model.rows(from: cards)
        #expect(rows.count == 3)

        let summary = model.summary(of: rows)
        #expect(summary.cardCount == 6)
        #expect(summary.marketCents == 8_103 + 197 + 5 * 4)
        #expect(summary.basisCents == 4_100 + 1_600)
        // The slab cost $41 and the pull's split cost was $16. Both count.
        #expect(summary.pricedBasisCents == 4_100 + 1_600)
        #expect(summary.pricedMarketCents == 8_103 + 197)
        #expect(summary.unrealizedCents == 8_103 + 197 - 4_100 - 1_600)
        // Still reported, so he can see which costs were derived.
        #expect(summary.allocatedCount == 1)

        let pull = try #require(rows.first { $0.card.productId == 2 })
        #expect(pull.unrealizedCents == 197 - 1_600)
        let slab = try #require(rows.first { $0.card.productId == 1 })
        #expect(slab.unrealizedCents == 4_003)
        // A bulk card carries no cost of its own, so it has no gain to read.
        let bulk = try #require(rows.first { $0.card.productId == 3 })
        #expect(bulk.unrealizedCents == nil)
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

    /// A sold card is not inventory. It stays out of the page, out of the
    /// collection half of a search, and out of the totals — with no chip to
    /// bring it back. The search path is the one that used to leak, because
    /// `applyFilter: false` skipped the sold check with everything else.
    @Test @MainActor func aSoldCardIsGoneFromEveryInventoryView() throws {
        try seed(container.mainContext)
        let model = InventoryModel()
        model.setTestRows(hits: [1: hit(1, group: 100), 2: hit(2, group: 101), 3: hit(3, group: 101)], prices: [:])
        let cards = try container.mainContext.fetch(FetchDescriptor<OwnedCard>())
        let sold = try #require(cards.first { $0.productId == 2 })

        #expect(model.rows(from: cards).contains { $0.card.productId == 2 })

        // What the sell flow writes, and nothing else.
        CardTagEditor(context: container.mainContext).add(ReservedTag.sold, to: [sold])
        try container.mainContext.save()
        #expect(sold.status == .owned)

        // The inventory page.
        #expect(!model.rows(from: cards).contains { $0.card.productId == 2 })
        // The collection half of a search, which does not apply the chips.
        #expect(!model.rows(from: cards, applyFilter: false).contains { $0.card.productId == 2 })
        // Metrics reports what the page left, so the pull's $16.00 goes with
        // it and only the slab's $41.00 remains.
        #expect(model.summary(of: model.rows(from: cards)).basisCents == 4_100)

        // An imported row carries the status and no label until the backfill
        // runs. It must be gone too.
        let imported = try #require(cards.first { $0.productId == 3 })
        imported.status = .sold
        try container.mainContext.save()
        #expect(!model.rows(from: cards, applyFilter: false).contains { $0.card.productId == 3 })
    }

    /// Unsell on the order is the only way back now that the chip is gone, so
    /// it has to actually work.
    @Test @MainActor func unsellingPutsTheCardBackInInventory() throws {
        try seed(container.mainContext)
        let model = InventoryModel()
        model.setTestRows(hits: [1: hit(1, group: 100), 2: hit(2, group: 101), 3: hit(3, group: 101)], prices: [:])
        let cards = try container.mainContext.fetch(FetchDescriptor<OwnedCard>())
        let card = try #require(cards.first { $0.productId == 2 })

        let editor = CardTagEditor(context: container.mainContext)
        editor.add(ReservedTag.sold, to: [card])
        try container.mainContext.save()
        #expect(!model.rows(from: cards).contains { $0.card.productId == 2 })

        // What `SaleDetailView.unsell` does.
        editor.remove(ReservedTag.sold, from: [card])
        try container.mainContext.save()

        #expect(model.rows(from: cards).contains { $0.card.productId == 2 })
        // Its cost came back with it, so the totals reconcile again.
        #expect(model.summary(of: model.rows(from: cards)).basisCents == 5_700)
        // And the card kept the comps he typed in by hand.
        #expect(card.gradedCompCents == ["10": 12_000, "9.5": 5_100])
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
