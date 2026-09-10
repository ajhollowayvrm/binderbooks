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
}
