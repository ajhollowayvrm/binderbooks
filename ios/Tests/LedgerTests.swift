import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// The ledger is one list of money in and money out. These cover the arithmetic
/// and the ordering; `SeedLedgerImportTests` covers it against the real books.
@Suite struct LedgerTests {
    private func day(_ iso: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.date(from: iso)!
    }

    @MainActor private func store() throws -> ModelContainer {
        try CollectionStore.container(inMemory: true)
    }

    @Test @MainActor func moneyOutIsNegativeAndMoneyInIsNet() throws {
        let container = try store()
        let context = container.mainContext

        let purchase = Purchase(date: day("2026-08-17"), vendor: "Gamecraft", itemCostCents: 19_339)
        purchase.shippingCents = 500
        context.insert(purchase)

        let sale = Sale(soldAt: day("2026-08-20"), channelRaw: "tcgplayer", grossCents: 1_515)
        sale.marketplaceFeesCents = 232
        sale.shippingCostCents = 78
        context.insert(sale)

        let grading = GradingSubmission(graderRaw: "psa", shippedAt: day("2026-08-18"), gradingFeesCents: 26_897)
        context.insert(grading)
        try context.save()

        let entries = LedgerEntry.entries(
            purchases: try context.fetch(FetchDescriptor<Purchase>()),
            grading: try context.fetch(FetchDescriptor<GradingSubmission>()),
            sales: try context.fetch(FetchDescriptor<Sale>())
        )

        #expect(entries.count == 3)
        // Newest first, so the sale leads.
        #expect(entries.map(\.date) == [day("2026-08-20"), day("2026-08-18"), day("2026-08-17")])

        let saleEntry = try #require(entries.first)
        #expect(saleEntry.isMoneyIn)
        #expect(saleEntry.amountCents == 1_205)
        #expect(saleEntry.title == "TCGplayer")

        let purchaseEntry = try #require(entries.last)
        #expect(!purchaseEntry.isMoneyIn)
        // Landed cost, not the item price.
        #expect(purchaseEntry.amountCents == -19_839)

        let gradingEntry = entries[1]
        #expect(gradingEntry.amountCents == -26_897)
        #expect(gradingEntry.detail == "no cards attached")
    }

    @Test func aMonthCarriesItsOwnTwoTotals() {
        let entries = [
            LedgerEntry(kind: .sale(UUID()), date: day("2026-08-20"), title: "TCGplayer", detail: "", amountCents: 1_205),
            LedgerEntry(kind: .sale(UUID()), date: day("2026-08-02"), title: "eBay", detail: "", amountCents: 3_000),
            LedgerEntry(kind: .purchase(UUID()), date: day("2026-08-17"), title: "Gamecraft", detail: "", amountCents: -19_839),
            LedgerEntry(kind: .purchase(UUID()), date: day("2026-07-04"), title: "Walmart", detail: "", amountCents: -500),
        ]

        let months = LedgerMonth.group(entries)
        #expect(months.count == 2)

        let august = months[0]
        #expect(august.entries.count == 3)
        #expect(august.moneyInCents == 4_205)
        // Money out reads positive in a total, and negative in a row.
        #expect(august.moneyOutCents == 19_839)

        let july = months[1]
        #expect(july.moneyInCents == 0)
        #expect(july.moneyOutCents == 500)
    }

    @Test func theFilterKeepsOneSideOfTheLedger() {
        let sale = LedgerEntry(kind: .sale(UUID()), date: .now, title: "eBay", detail: "", amountCents: 3_000)
        let purchase = LedgerEntry(kind: .purchase(UUID()), date: .now, title: "Walmart", detail: "", amountCents: -500)

        #expect(LedgerFilter.all.keeps(sale) && LedgerFilter.all.keeps(purchase))
        #expect(LedgerFilter.moneyIn.keeps(sale) && !LedgerFilter.moneyIn.keeps(purchase))
        #expect(!LedgerFilter.moneyOut.keeps(sale) && LedgerFilter.moneyOut.keeps(purchase))
    }

    /// A sale of nothing is still money. Thirty-five of his orders are like this.
    @Test @MainActor func anOrderWithNoCardsStillShows() throws {
        let container = try store()
        let sale = Sale(soldAt: day("2026-06-01"), channelRaw: "tcgplayer", grossCents: 1_148)
        container.mainContext.insert(sale)
        try container.mainContext.save()

        let entries = LedgerEntry.entries(purchases: [], grading: [], sales: [sale])
        #expect(entries.first?.detail == "no cards recorded")
        #expect(entries.first?.amountCents == 1_148)
    }

    @Test func aTypedChannelMatchesTheImportedRows() {
        // "TCGplayer" typed by hand must land on the same key the import wrote,
        // or the ledger shows two channels that are one channel.
        #expect(AddTransactionSheet.channelKey("TCGplayer") == "tcgplayer")
        #expect(AddTransactionSheet.channelKey("  tcgp ") == "tcgplayer")
        #expect(AddTransactionSheet.channelKey("eBay") == "ebay")
        #expect(LedgerEntry.channelName(AddTransactionSheet.channelKey("TCGplayer")) == "TCGplayer")
        // Anything else keeps his words, folded.
        #expect(AddTransactionSheet.channelKey("Card Kingdom") == "card kingdom")
    }

    @Test @MainActor func aPurchaseAddedByHandLandsInTheLedgerAsMoneyOut() throws {
        let container = try store()
        let context = container.mainContext

        // What the sheet writes: item cost plus everything that came off it.
        let purchase = Purchase(
            date: day("2026-09-09"), vendor: "Gamecraft", note: "6x Chaos Rising Booster Pack",
            itemCostCents: 2_400, shippingCents: 500, taxCents: 210, feesCents: 90
        )
        context.insert(purchase)
        try context.save()

        let entry = try #require(LedgerEntry.entries(purchases: [purchase], grading: [], sales: []).first)
        #expect(!entry.isMoneyIn)
        #expect(entry.amountCents == -3_200)
        #expect(entry.title == "Gamecraft")
        #expect(entry.detail == "6x Chaos Rising Booster Pack")
    }

    /// An order he types has no cards, exactly like the 35 imported ones.
    @Test @MainActor func anOrderAddedByHandReportsNoGain() throws {
        let container = try store()
        let sale = Sale(soldAt: day("2026-09-09"), channelRaw: "tcgplayer", grossCents: 4_300)
        sale.marketplaceFeesCents = 681
        sale.shippingCostCents = 597
        container.mainContext.insert(sale)
        try container.mainContext.save()

        #expect(sale.netCents == 3_022)
        #expect(sale.realizedGainCents == nil)
    }

    @Test @MainActor func anExpenseIsMoneyOut() throws {
        let container = try store()
        let context = container.mainContext

        let expense = BusinessExpense(
            date: day("2026-08-04"), category: "Supplies", vendor: "Amazon",
            amountCents: 2_499, note: "500 penny sleeves"
        )
        context.insert(expense)
        try context.save()

        let entries = LedgerEntry.entries(purchases: [], grading: [], sales: [], expenses: [expense])
        let entry = try #require(entries.first)
        #expect(!entry.isMoneyIn)
        #expect(entry.amountCents == -2_499)
        #expect(entry.title == "Amazon")
        #expect(entry.detail == "Supplies")

        let month = try #require(LedgerMonth.group(entries).first)
        #expect(month.moneyOutCents == 2_499)
    }

    /// Cards he has sold keep their row and their basis. Counting them would
    /// inflate ending inventory, the position, and the profit all at once.
    @Test @MainActor func endingInventoryIgnoresACardThatSold() throws {
        let container = try store()
        let context = container.mainContext

        let held = OwnedCard(productId: 1, printing: "Normal", condition: "Near Mint", confidence: .manual)
        held.acquisitionBasisCents = 1_000
        context.insert(held)

        let sold = OwnedCard(productId: 2, printing: "Normal", condition: "Near Mint", confidence: .manual)
        sold.acquisitionBasisCents = 5_000
        sold.status = .sold
        context.insert(sold)

        let lost = OwnedCard(productId: 3, printing: "Normal", condition: "Near Mint", confidence: .manual)
        lost.acquisitionBasisCents = 700
        lost.status = .lost
        context.insert(lost)

        let atGrader = OwnedCard(productId: 4, printing: "Normal", condition: "Near Mint", confidence: .manual)
        atGrader.acquisitionBasisCents = 300
        atGrader.gradingBasisCents = 200
        atGrader.status = .atGrader
        context.insert(atGrader)
        try context.save()

        let cards = try context.fetch(FetchDescriptor<OwnedCard>())
        let inventory = cards.filter(LedgerSummary.isHeld)
        #expect(inventory.count == 2)

        let s = LedgerSummary.make(
            purchases: [], grading: [], sales: [], expenses: [],
            held: inventory, marketCents: { _ in nil }
        )
        // 1000 held + (300 + 200) at the grader. The 5000 sold and the 700 lost
        // are gone.
        #expect(s.endingInventoryCents == 1_500)
        #expect(s.heldCardCount == 2)
        #expect(s.atGraderCount == 1)
    }

    /// `SellSheet` writes the `sold` label and never touches `statusRaw`, so a
    /// card sold in the app still reads `owned` there. A held filter that
    /// trusted the status would count every one of them as inventory.
    @Test @MainActor func aCardSoldInTheAppIsNotInventoryEither() throws {
        let container = try store()
        let context = container.mainContext

        let card = OwnedCard(productId: 1, printing: "Normal", condition: "Near Mint", confidence: .manual)
        card.acquisitionBasisCents = 4_000
        context.insert(card)
        try context.save()

        // Exactly what the sell flow does.
        CardTagEditor(context: context).add(ReservedTag.sold, to: [card])
        try context.save()

        #expect(card.status == .owned)
        #expect(!LedgerSummary.isHeld(card))

        let s = LedgerSummary.make(
            purchases: [], grading: [], sales: [], expenses: [],
            held: [card].filter(LedgerSummary.isHeld), marketCents: { _ in nil }
        )
        #expect(s.endingInventoryCents == 0)
        #expect(s.heldCardCount == 0)
    }

    /// The same for a card out at a grader: the send flow writes "at PSA", not
    /// the status, and that card is still inventory he owns.
    @Test @MainActor func aCardAtAGraderCountsByItsLabel() throws {
        let container = try store()
        let context = container.mainContext

        let card = OwnedCard(productId: 1, printing: "Normal", condition: "Near Mint", confidence: .manual)
        card.acquisitionBasisCents = 3_000
        context.insert(card)
        try context.save()

        CardTagEditor(context: context).add(ReservedTag.atPSA, to: [card])
        try context.save()

        #expect(LedgerSummary.isHeld(card))
        let s = LedgerSummary.make(
            purchases: [], grading: [], sales: [], expenses: [],
            held: [card], marketCents: { _ in nil }
        )
        #expect(s.endingInventoryCents == 3_000)
        #expect(s.atGraderCount == 1)
    }

    @Test @MainActor func profitIsNotReportedForAnOrderWithNoBasis() throws {
        let container = try store()
        let context = container.mainContext

        let card = OwnedCard(productId: 1, printing: "Normal", condition: "Near Mint", confidence: .manual)
        context.insert(card)

        let known = Sale(soldAt: day("2026-08-20"), channelRaw: "tcgplayer", grossCents: 5_000)
        known.marketplaceFeesCents = 500
        let line = SaleLine(sale: known, card: card, basisCents: 1_000)
        known.lines = [line]
        context.insert(known)
        context.insert(line)

        // A price and no card, like the 35 imported orders.
        let unknown = Sale(soldAt: day("2026-08-21"), channelRaw: "ebay", grossCents: 9_900)
        context.insert(unknown)
        try context.save()

        let s = LedgerSummary.make(
            purchases: [], grading: [], sales: [known, unknown], expenses: [],
            held: [], marketCents: { _ in nil }
        )
        // 4500 net less 1000 of basis. The eBay order contributes nothing.
        #expect(s.realizedGainCents == 3_500)
        #expect(s.ordersWithKnownBasis == 1)
        #expect(s.orderCount == 2)
        #expect(s.ordersWithUnknownBasis == 1)
        // Revenue is not the same thing. Both orders are real money.
        #expect(s.revenueCents == 4_500 + 9_900)
    }

    @Test @MainActor func theProfitAndLossFollowsThePeriodicFormula() throws {
        let container = try store()
        let context = container.mainContext

        let purchase = Purchase(date: day("2026-08-17"), vendor: "Gamecraft", itemCostCents: 10_000)
        purchase.shippingCents = 1_000
        context.insert(purchase)

        let grading = GradingSubmission(graderRaw: "psa", shippedAt: day("2026-08-18"), gradingFeesCents: 2_000)
        grading.shipToGraderCents = 500
        context.insert(grading)

        let sale = Sale(soldAt: day("2026-08-20"), channelRaw: "tcgplayer", grossCents: 8_000)
        sale.marketplaceFeesCents = 1_000
        context.insert(sale)

        let expense = BusinessExpense(date: day("2026-08-21"), vendor: "Amazon", amountCents: 2_499)
        context.insert(expense)

        let held = OwnedCard(productId: 1, printing: "Normal", condition: "Near Mint", confidence: .manual)
        held.acquisitionBasisCents = 6_000
        context.insert(held)
        try context.save()

        let s = LedgerSummary.make(
            purchases: [purchase], grading: [grading], sales: [sale], expenses: [expense],
            held: [held], marketCents: { _ in nil }
        )

        #expect(s.beginningInventoryCents == 0)
        // Landed cost plus the grading charge. Grading is capitalised into the
        // card, so it counts on both sides.
        #expect(s.purchasesCents == 11_000 + 2_500)
        #expect(s.endingInventoryCents == 6_000)
        #expect(s.revenueCents == 7_000)
        #expect(s.expensesCents == 2_499)

        // COGS = 0 + 13500 − 6000
        #expect(s.costOfGoodsSoldCents == 7_500)
        // P&L = 7000 − 7500 − 2499
        #expect(s.profitCents == -2_999)

        // Cash is a different reading of the same rows, and it disagrees. That
        // is the point of showing both.
        #expect(s.moneyInCents == 7_000)
        #expect(s.moneyOutCents == 11_000 + 2_500 + 2_499)
    }

    /// The whole ledger reconciles with the books.
    @Test @MainActor func theRealLedgerAddsUp() throws {
        let data = try Data(contentsOf: SeedLedgerImportTests.file)
        let file = try CollectionExport.decode(data)
        let container = try store()
        try CollectionExport.apply(file, to: container.mainContext, mode: .replace)
        let context = container.mainContext

        let entries = LedgerEntry.entries(
            purchases: try context.fetch(FetchDescriptor<Purchase>()),
            grading: try context.fetch(FetchDescriptor<GradingSubmission>()),
            sales: try context.fetch(FetchDescriptor<Sale>())
        )
        #expect(entries.count == 93 + 8 + 131)

        let moneyIn = entries.filter(\.isMoneyIn).reduce(0) { $0 + $1.amountCents }
        let moneyOut = -entries.filter { !$0.isMoneyIn }.reduce(0) { $0 + $1.amountCents }
        #expect(moneyIn == 292_210)
        #expect(moneyOut == 1_128_302 + 175_288)

        // docs/04 prints six months of cash flow, 2026-04 to 2026-09.
        #expect(LedgerMonth.group(entries).count == 6)
    }

    /// Summary moved the cash figures off the transaction list. They must still
    /// be the same figures, so this asserts them against the numbers
    /// `theRealLedgerAddsUp` already guards.
    @Test @MainActor func theRealBooksSummaryAgreesWithTheLedger() throws {
        let data = try Data(contentsOf: SeedLedgerImportTests.file)
        let file = try CollectionExport.decode(data)
        let container = try store()
        try CollectionExport.apply(file, to: container.mainContext, mode: .replace)
        let context = container.mainContext

        let cards = try context.fetch(FetchDescriptor<OwnedCard>())
        let s = LedgerSummary.make(
            purchases: try context.fetch(FetchDescriptor<Purchase>()),
            grading: try context.fetch(FetchDescriptor<GradingSubmission>()),
            sales: try context.fetch(FetchDescriptor<Sale>()),
            expenses: try context.fetch(FetchDescriptor<BusinessExpense>()),
            held: cards.filter { $0.isCommitted && LedgerSummary.isHeld($0) },
            // No catalog in a test, so nothing is priced. The cost side is what
            // this test is for.
            marketCents: { _ in nil }
        )

        // The same two numbers the transaction list used to print on top.
        #expect(s.moneyInCents == 292_210)
        #expect(s.moneyOutCents == 1_128_302 + 175_288)
        // Revenue is money in, and purchases are money out, while there are no
        // expenses on his books yet.
        #expect(s.revenueCents == s.moneyInCents)
        #expect(s.purchasesCents == s.moneyOutCents)
        #expect(s.expensesCents == 0)

        // 131 orders, and 69 of them recorded a price and no card.
        #expect(s.orderCount == 131)
        #expect(s.ordersWithKnownBasis == 62)
        #expect(s.ordersWithUnknownBasis == 69)

        // Cards he has sold are not inventory. If this ever equals the whole
        // card count, the held filter has stopped working.
        #expect(s.endingInventoryCents == 546_352)
        #expect(cards.filter(LedgerSummary.isHeld).count < cards.count)

        #expect(s.costOfGoodsSoldCents == 757_238)
        #expect(s.profitCents == -465_028)
    }
}
