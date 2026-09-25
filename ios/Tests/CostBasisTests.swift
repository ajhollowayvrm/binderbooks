import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// A card's cost since 2026-09-25: the fresh start, the split by market, the
/// rip, the grading share, and the Summary that reads them. Each test keeps
/// the books start in its own `UserDefaults` suite.
@Suite @MainActor struct CostBasisTests {
    let container: ModelContainer
    let defaults: UserDefaults

    init() throws {
        container = try CollectionStore.container(inMemory: true)
        defaults = try #require(UserDefaults(suiteName: "CostBasisTests.\(UUID().uuidString)"))
    }

    private var context: ModelContext { container.mainContext }

    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private var before: Date { start.addingTimeInterval(-86_400) }
    private var after: Date { start.addingTimeInterval(86_400) }

    private func card(_ productId: Int, sealed: Bool = false) -> OwnedCard {
        let card = OwnedCard(productId: productId, printing: "Normal", condition: CardCondition.nearMint.rawValue, confidence: .manual)
        card.isSealedSelf = sealed
        context.insert(card)
        return card
    }

    // MARK: - Splits

    @Test func aWeightedSplitSumsBackExactly() {
        #expect(CostBasis.splitByWeight(100, weights: [1, 1, 1]) == [34, 33, 33])
        #expect(CostBasis.splitByWeight(1_000, weights: [300, 100]) == [750, 250])
        // No weight at all: equal.
        #expect(CostBasis.splitByWeight(10, weights: [0, 0]) == [5, 5])
        let shares = CostBasis.splitByWeight(9_999, weights: [7, 13, 0, 29])
        #expect(shares.reduce(0, +) == 9_999)
        #expect(shares[2] == 0)
    }

    // MARK: - Fresh start

    /// Every card he holds at the start costs $0, a typed cost too. The start
    /// is set only once.
    @Test func theFreshStartZeroesEveryCardOnce() throws {
        let typed = card(1)
        typed.acquisitionBasisCents = 2_500
        typed.basisIsManual = true
        let split = card(2)
        split.acquisitionBasisCents = 700
        split.basisIsAllocated = true
        try context.save()

        Books.startFresh(context, now: start, defaults: defaults)

        #expect(Books.start(defaults) == start)
        #expect([typed, split].allSatisfy { $0.acquisitionBasisCents == 0 && !$0.basisIsManual && !$0.basisIsAllocated })

        typed.acquisitionBasisCents = 300
        Books.startFresh(context, now: after, defaults: defaults)
        #expect(Books.start(defaults) == start)
        #expect(typed.acquisitionBasisCents == 300)
    }

    /// A file from before the fresh start has no start. Its cards import at
    /// $0. A file with a start keeps its costs and sets the start.
    @Test func anOldExportImportsAtZero() throws {
        let old = card(1)
        old.acquisitionBasisCents = 1_234
        old.basisIsAllocated = true
        try context.save()
        var file = try CollectionExport.snapshot(context, defaults: defaults)
        #expect(file.booksStartedAt == nil)

        let target = try CollectionStore.container(inMemory: true)
        Books.setStart(start, defaults: defaults)
        try CollectionExport.apply(file, to: target.mainContext, mode: .merge, defaults: defaults)
        let imported = try target.mainContext.fetch(FetchDescriptor<OwnedCard>())
        #expect(imported.map(\.acquisitionBasisCents) == [0])

        file.booksStartedAt = after
        let other = try CollectionStore.container(inMemory: true)
        try CollectionExport.apply(file, to: other.mainContext, mode: .merge, defaults: defaults)
        #expect(try other.mainContext.fetch(FetchDescriptor<OwnedCard>()).map(\.acquisitionBasisCents) == [1_234])
        #expect(Books.start(defaults) == after)
    }

    // MARK: - Rips

    /// A $30 box ripped into a $40 hit and a $10 common: the hit takes $24.
    /// The line keeps its cost, so a later shipping fix on the purchase goes
    /// to the other line and not to the ripped one.
    @Test func aRipMovesThePackCostToThePullsByMarket() throws {
        let purchase = Purchase(date: after, vendor: "Target", itemCostCents: 4_000)
        context.insert(purchase)
        let boxLine = PurchaseItem(productId: 100, isSealed: true)
        boxLine.purchase = purchase
        context.insert(boxLine)
        let singleLine = PurchaseItem(productId: 200)
        singleLine.purchase = purchase
        context.insert(singleLine)
        let box = card(100, sealed: true)
        box.sourceItem = boxLine
        let single = card(200)
        single.sourceItem = singleLine
        let market = [100: 3_000, 200: 1_000, 10: 4_000, 11: 1_000]
        CostBasis.split(purchase, since: start, marketCents: { market[$0.productId] })
        try context.save()
        #expect(box.acquisitionBasisCents == 3_000)
        #expect(single.acquisitionBasisCents == 1_000)

        let session = try #require(Rip.start([box], context: context, defaults: defaults))
        let hit = card(10)
        hit.scanSession = session
        let common = card(11)
        common.scanSession = session
        try context.save()
        Rip.finish(session, context: context, marketCents: { market[$0.productId] }, defaults: defaults)

        #expect(hit.acquisitionBasisCents == 2_400)
        #expect(common.acquisitionBasisCents == 600)
        #expect(boxLine.isRipped)
        #expect(boxLine.allocatedCostCents == 3_000)

        var details = PurchaseEditor.Details(purchase)
        details.shippingCents = 500
        try PurchaseEditor.apply(details, to: purchase, since: start, marketCents: { market[$0.productId] }, context: context)
        #expect(single.acquisitionBasisCents == 1_500)
        #expect(hit.acquisitionBasisCents == 2_400)
    }

    // MARK: - Grading

    /// A charge dated before the start is off the books and puts nothing on a
    /// card. A charge after it splits equally.
    @Test func onlyGradingOnTheBooksCountsInCost() throws {
        let a = card(1)
        let b = card(2)
        let old = GradingSubmission(graderRaw: "psa", shippedAt: before, gradingFeesCents: 9_000)
        let new = GradingSubmission(graderRaw: "cgc", shippedAt: after, gradingFeesCents: 3_001)
        context.insert(old)
        context.insert(new)
        for card in [a, b] {
            context.insert(GradingEntry(submission: old, card: card))
            context.insert(GradingEntry(submission: new, card: card))
        }
        try context.save()

        let shares = CostBasis.gradingShares([old, new], since: start)
        #expect((shares[a.id] ?? 0) + (shares[b.id] ?? 0) == 3_001)
        #expect(Set([shares[a.id], shares[b.id]]) == [1_501, 1_500])
    }

    // MARK: - Summary

    /// The Summary counts only rows on the books. A sale's gain takes off the
    /// cost of its cards, grading included.
    @Test func theSummaryCountsFromTheStartAndTakesOffCost() throws {
        let oldPurchase = Purchase(date: before, vendor: "Old", itemCostCents: 100_000)
        let newPurchase = Purchase(date: after, vendor: "New", itemCostCents: 2_000)
        context.insert(oldPurchase)
        context.insert(newPurchase)

        let sold = card(1)
        sold.acquisitionBasisCents = 1_200
        let held = card(2)
        held.acquisitionBasisCents = 800
        let submission = GradingSubmission(graderRaw: "psa", shippedAt: after, gradingFeesCents: 500)
        context.insert(submission)
        context.insert(GradingEntry(submission: submission, card: sold))

        let oldSale = Sale(soldAt: before, channelRaw: "tcgplayer", grossCents: 50_000)
        let newSale = Sale(soldAt: after, channelRaw: "tcgplayer", grossCents: 3_000)
        context.insert(oldSale)
        context.insert(newSale)
        context.insert(SaleLine(sale: newSale, card: sold))
        let unknown = SaleLine(sale: newSale)
        unknown.describedAs = "Pikachu"
        context.insert(unknown)
        CardTagEditor(context: context).add(ReservedTag.sold, to: [sold])
        let expense = BusinessExpense(date: before, category: "Supplies", amountCents: 999)
        context.insert(expense)
        try context.save()

        let s = LedgerSummary.make(
            purchases: [oldPurchase, newPurchase], grading: [submission], sales: [oldSale, newSale],
            expenses: [expense], held: [held], since: start, marketCents: { _ in 1_000 }
        )

        #expect(s.purchasesCents == 2_000)
        #expect(s.gradingCents == 500)
        #expect(s.expensesCents == 0)
        #expect(s.revenueCents == 3_000)
        #expect(s.profitCents == 500)
        #expect(s.soldCostCents == 1_700)
        #expect(s.gainOnSalesCents == 1_300)
        #expect(s.soldLinesWithoutCardCount == 1)
        #expect(s.heldAtCostCents == 800)
        #expect(s.heldAtMarketCents == 1_000)
    }
}
