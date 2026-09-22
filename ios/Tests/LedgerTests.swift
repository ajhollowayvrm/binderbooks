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

    /// The row says how many items the purchase lists. A line of several
    /// copies counts each copy, and no card is involved.
    @Test @MainActor func aPurchaseRowCountsItsItems() throws {
        let container = try store()
        let context = container.mainContext
        let purchase = Purchase(date: day("2026-09-09"), vendor: "Whatnot", note: "Lot", itemCostCents: 4_000)
        context.insert(purchase)
        for quantity in [3, 1] {
            let item = PurchaseItem(productId: 42, quantity: quantity, isSealed: true)
            context.insert(item)
            item.purchase = purchase
        }
        try context.save()

        #expect(LedgerEntry.itemSummary(purchase) == "4 items")
        let entry = try #require(LedgerEntry.entries(purchases: [purchase], grading: [], sales: []).first)
        #expect(entry.detail == "4 items · Lot")

        let one = Purchase(date: day("2026-09-09"), vendor: "Walmart", itemCostCents: 500)
        context.insert(one)
        let item = PurchaseItem(productId: 7)
        context.insert(item)
        item.purchase = one
        try context.save()
        #expect(LedgerEntry.itemSummary(one) == "1 item")

        let empty = Purchase(date: day("2026-09-09"), vendor: "Walmart", itemCostCents: 500)
        context.insert(empty)
        try context.save()
        #expect(LedgerEntry.itemSummary(empty) == "")
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

    /// Cards he has sold keep their row. Counting them would inflate what he
    /// holds at market.
    @Test @MainActor func heldAtMarketIgnoresACardThatSold() throws {
        let container = try store()
        let context = container.mainContext

        let held = OwnedCard(productId: 1, printing: "Normal", condition: "Near Mint", confidence: .manual)
        context.insert(held)

        let sold = OwnedCard(productId: 2, printing: "Normal", condition: "Near Mint", confidence: .manual)
        sold.status = .sold
        context.insert(sold)

        let lost = OwnedCard(productId: 3, printing: "Normal", condition: "Near Mint", confidence: .manual)
        lost.status = .lost
        context.insert(lost)

        let atGrader = OwnedCard(productId: 4, printing: "Normal", condition: "Near Mint", confidence: .manual)
        atGrader.status = .atGrader
        context.insert(atGrader)
        try context.save()

        let cards = try context.fetch(FetchDescriptor<OwnedCard>())
        let inventory = cards.filter(LedgerSummary.isHeld)
        #expect(inventory.count == 2)

        let market: [Int: Int] = [1: 1_000, 2: 5_000, 3: 700, 4: 500]
        let s = LedgerSummary.make(
            purchases: [], grading: [], sales: [], expenses: [],
            held: inventory, marketCents: { market[$0.productId] }
        )
        // 1000 held + 500 at the grader. The 5000 sold and the 700 lost are gone.
        #expect(s.heldAtMarketCents == 1_500)
        #expect(s.heldCardCount == 2)
        #expect(s.atGraderCount == 1)
    }

    /// His call, 2026-09-22: a card he keeps does not count in what he could
    /// sell today. A card of his at a grader still counts as at the grader.
    @Test @MainActor func thePersonalCollectionIsNotInIfYouSoldToday() throws {
        let container = try store()
        let context = container.mainContext

        let stock = OwnedCard(productId: 1, printing: "Normal", condition: "Near Mint", confidence: .manual)
        context.insert(stock)
        let kept = OwnedCard(productId: 2, printing: "Normal", condition: "Near Mint", confidence: .manual)
        kept.isPersonalCollection = true
        kept.tags = [ReservedTag.atGrader("psa")]
        context.insert(kept)
        try context.save()

        let market: [Int: Int] = [1: 1_000, 2: 50_000]
        let s = LedgerSummary.make(
            purchases: [], grading: [], sales: [], expenses: [],
            held: [stock, kept], marketCents: { market[$0.productId] }
        )
        #expect(s.heldCardCount == 1)
        #expect(s.heldAtMarketCents == 1_000)
        // "What you have" still shows the card he keeps, on a line of its own.
        #expect(s.personalCardCount == 1)
        #expect(s.personalAtMarketCents == 50_000)
        #expect(s.atGraderCount == 1)
        let costs = SellingCosts(rateBasisPoints: 1_000)
        #expect(s.ifSoldTodayCents(costs) == s.profitCents + costs.net(1_000))
    }

    /// An imported card keeps `statusRaw` at `atGrader`. "Mark graded" used to
    /// take off only the label, so the Summary still counted the card as out
    /// at a grader after he had graded it PSA 10.
    @Test @MainActor func aCardMarkedGradedIsNoLongerAtTheGrader() throws {
        let container = try store()
        let context = container.mainContext

        let card = OwnedCard(productId: 1, printing: "Normal", condition: "Near Mint", confidence: .manual)
        card.status = .atGrader
        context.insert(card)
        try context.save()
        #expect(LedgerSummary.isAtGrader(card))

        // What the store already holds: a grade and the "graded" label, with
        // the old status left behind.
        card.graderRaw = "psa"
        card.gradeLabel = "10"
        CardTagEditor(context: context).add(ReservedTag.graded, to: [card])
        try context.save()

        #expect(card.status == .atGrader)
        #expect(!LedgerSummary.isAtGrader(card))

        // A slab sent back for a regrade wears the label again, and counts.
        CardTagEditor(context: context).add(ReservedTag.atPSA, to: [card])
        #expect(LedgerSummary.isAtGrader(card))
    }

    /// `SellSheet` writes the `sold` label and never touches `statusRaw`, so a
    /// card sold in the app still reads `owned` there. A held filter that
    /// trusted the status would count every one of them as inventory.
    @Test @MainActor func aCardSoldInTheAppIsNotInventoryEither() throws {
        let container = try store()
        let context = container.mainContext

        let card = OwnedCard(productId: 1, printing: "Normal", condition: "Near Mint", confidence: .manual)
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
        #expect(s.heldCardCount == 0)
    }

    /// The same for a card out at a grader: the send flow writes "at PSA", not
    /// the status, and that card is still inventory he owns.
    @Test @MainActor func aCardAtAGraderCountsByItsLabel() throws {
        let container = try store()
        let context = container.mainContext

        let card = OwnedCard(productId: 1, printing: "Normal", condition: "Near Mint", confidence: .manual)
        context.insert(card)
        try context.save()

        CardTagEditor(context: context).add(ReservedTag.atPSA, to: [card])
        try context.save()

        #expect(LedgerSummary.isHeld(card))
        let s = LedgerSummary.make(
            purchases: [], grading: [], sales: [], expenses: [],
            held: [card], marketCents: { _ in nil }
        )
        #expect(s.atGraderCount == 1)
    }

    @Test @MainActor func profitIsSalesLessEverythingSpent() throws {
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
        context.insert(held)
        try context.save()

        let s = LedgerSummary.make(
            purchases: [purchase], grading: [grading], sales: [sale], expenses: [expense],
            held: [held], marketCents: { _ in 6_000 }
        )

        #expect(s.revenueCents == 7_000)
        #expect(s.purchasesCents == 11_000)
        #expect(s.gradingCents == 2_500)
        #expect(s.expensesCents == 2_499)
        // Spent is everything that went out, in one figure.
        #expect(s.spentCents == 11_000 + 2_500 + 2_499)
        // Earned less spent: 7000 − 15999
        #expect(s.profitCents == -8_999)
        // The profit is money in less money out.
        #expect(s.profitCents == s.differenceCents)
        #expect(s.moneyInCents == 7_000)
        #expect(s.moneyOutCents == 11_000 + 2_500 + 2_499)

        // A priced card he holds does not change the profit. It shows in
        // "If you sold today" instead.
        let none = LedgerSummary.make(
            purchases: [purchase], grading: [grading], sales: [sale], expenses: [expense],
            held: [], marketCents: { _ in nil }
        )
        #expect(none.profitCents == s.profitCents)
        #expect(s.heldAtMarketCents == 6_000)
        #expect(s.ifSoldTodayCents(SellingCosts(rateBasisPoints: 0)) == -8_999 + 6_000)
    }

    // MARK: - Selling costs

    @Test @MainActor func aDerivedRateComesFromHisOwnOrders() throws {
        let container = try store()
        let context = container.mainContext

        let one = Sale(soldAt: day("2026-08-01"), channelRaw: "tcgplayer", grossCents: 10_000)
        one.marketplaceFeesCents = 1_000
        one.shippingCostCents = 300
        context.insert(one)
        let two = Sale(soldAt: day("2026-08-02"), channelRaw: "ebay", grossCents: 10_000)
        two.marketplaceFeesCents = 1_500
        two.shippingCostCents = 500
        context.insert(two)
        try context.save()

        let rates = ChannelRates.derived(from: [one, two])
        #expect(rates.orderCount == 2)
        // 2500 of 20000 is 12.50%, and shipping 800 of 20000 is 4.00%.
        #expect(rates.blendedFeeBasisPoints == 1_250)
        #expect(rates.shippingBasisPoints == 400)
        #expect(rates.totalBasisPoints == 1_650)
        // Biggest channel first, and each carries its own rate.
        #expect(rates.rows.count == 2)
        #expect(rates.rows.contains { $0.channelRaw == "ebay" && $0.feeBasisPoints == 1_500 })
        #expect(rates.rows.contains { $0.channelRaw == "tcgplayer" && $0.feeBasisPoints == 1_000 })

        // No override means the derived figure rules.
        #expect(SellingCostsKey.effective(override: nil, derived: rates).rateBasisPoints == 1_650)
        // His own number wins when he sets one.
        #expect(SellingCostsKey.effective(override: 900, derived: rates).rateBasisPoints == 900)
        // Text in, basis points out, and nonsense refused rather than zeroed.
        #expect(SellingCostsKey.basisPoints(from: "13.63") == 1_363)
        #expect(SellingCostsKey.basisPoints(from: "") == nil)
        #expect(SellingCostsKey.basisPoints(from: "100") == nil)
        #expect(SellingCostsKey.fieldText(1_363) == "13.63")
    }

    /// A grading charge counts once, as money out, and puts nothing on a card.
    @Test @MainActor func aGradingChargeCountsOnceAndTouchesNoCard() throws {
        let container = try store()
        let context = container.mainContext

        let one = OwnedCard(productId: 1, printing: "Normal", condition: "Near Mint", confidence: .manual)
        context.insert(one)
        let two = OwnedCard(productId: 2, printing: "Normal", condition: "Near Mint", confidence: .manual)
        context.insert(two)

        let submission = GradingSubmission(graderRaw: "psa", shippedAt: day("2026-09-01"), gradingFeesCents: 4_000)
        submission.shipToGraderCents = 1_000
        context.insert(submission)
        for card in [one, two] {
            context.insert(GradingEntry(submission: submission, card: card))
        }
        try context.save()

        let s = LedgerSummary.make(
            purchases: [], grading: [submission], sales: [], expenses: [],
            held: [one, two], marketCents: { _ in nil }
        )
        #expect(s.gradingCents == 5_000)
        #expect(s.purchasesCents == 0)
        #expect(s.profitCents == -5_000)
        #expect(one.gradingBasisCents == 0)
        #expect(two.gradingBasisCents == 0)
    }

    /// He sent two cards as PSA, and they went to CGC. The fix must reach the
    /// label the projection reads and the slab, not only the ledger row.
    @Test @MainActor func aSubmissionMovedToAnotherGraderTakesItsCards() throws {
        let container = try store()
        let context = container.mainContext

        let out = OwnedCard(productId: 1, printing: "Normal", condition: "Near Mint", confidence: .manual)
        out.tags = ["at PSA", "binder 3"]
        out.gradedCompCents = ["PSA 10": 20_000]
        context.insert(out)
        let back = OwnedCard(productId: 2, printing: "Normal", condition: "Near Mint", confidence: .manual)
        back.graderRaw = "psa"
        back.gradeLabel = "10"
        back.tags = ["graded"]
        context.insert(back)
        let elsewhere = OwnedCard(productId: 3, printing: "Normal", condition: "Near Mint", confidence: .manual)
        elsewhere.tags = ["at PSA"]
        context.insert(elsewhere)

        let submission = GradingSubmission(graderRaw: "psa", shippedAt: day("2026-09-01"), gradingFeesCents: 4_000)
        context.insert(submission)
        for card in [out, back] {
            context.insert(GradingEntry(submission: submission, card: card))
        }
        try context.save()

        GraderCorrection.change(submission, to: "CGC", context: context)

        #expect(submission.graderRaw == "cgc")
        #expect(LedgerEntry.entries(purchases: [], grading: [submission], sales: []).first?.title == "CGC grading")
        #expect(out.tags == ["at CGC", "binder 3"])
        #expect(GradedComps.graderAtGrader(tags: out.tags) == "cgc")
        // A PSA price is not a CGC price, so his figure stays where he typed it.
        #expect(out.gradedCompCents == ["PSA 10": 20_000])
        #expect(back.graderRaw == "cgc")
        #expect(back.tags == ["graded"])
        #expect(elsewhere.tags == ["at PSA"])

        // The same grader, in any case, and an empty one change nothing.
        GraderCorrection.change(submission, to: " cgc ", context: context)
        GraderCorrection.change(submission, to: "", context: context)
        #expect(submission.graderRaw == "cgc")
        #expect(out.tags == ["at CGC", "binder 3"])

        // And back again, for a wrong tap.
        GraderCorrection.change(submission, to: "psa", context: context)
        #expect(out.tags == ["at PSA", "binder 3"])
        #expect(back.graderRaw == "psa")
    }

    /// An empty book must not report that selling is free.
    @Test func aStoreWithNoOrdersHasNoDerivedRate() {
        let rates = ChannelRates.derived(from: [])
        #expect(rates.isEmpty)
        #expect(rates.totalBasisPoints == 0)
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
            // No catalog in a test, so nothing is priced. The money side is
            // what this test is for.
            marketCents: { _ in nil }
        )

        // The same two numbers the transaction list used to print on top.
        #expect(s.moneyInCents == 292_210)
        #expect(s.moneyOutCents == 1_128_302 + 175_288)
        // Revenue is money in. Purchases and grading are money out, while
        // there are no expenses on his books yet.
        #expect(s.revenueCents == s.moneyInCents)
        #expect(s.revenueCents == 292_210)
        #expect(s.purchasesCents == 1_128_302)
        #expect(s.gradingCents == 175_288)
        #expect(s.purchasesCents + s.gradingCents == s.moneyOutCents)
        #expect(s.expensesCents == 0)

        // Cards he has sold are not inventory. If this ever equals the whole
        // card count, the held filter has stopped working.
        #expect(cards.filter(LedgerSummary.isHeld).count < cards.count)

        // 292210 − 1128302 − 175288
        #expect(s.profitCents == -1_011_380)
        #expect(s.profitCents == s.differenceCents)
    }

    @Test @MainActor func theExportHasInAndOutColumns() throws {
        let container = try store()
        let context = container.mainContext
        let purchase = Purchase(date: day("2026-08-17"), vendor: "Game Grid, Inc", itemCostCents: 19_339)
        context.insert(purchase)
        let sale = Sale(soldAt: day("2026-08-20"), channelRaw: "tcgplayer", grossCents: 1_505)
        context.insert(sale)
        let charge = GradingSubmission(graderRaw: "psa", gradingFeesCents: 2_000)
        context.insert(charge)
        try context.save()

        let entries = LedgerEntry.entries(purchases: [purchase], grading: [charge], sales: [sale])
        let lines = LedgerExport.csv(entries).split(separator: "\n").map(String.init)

        #expect(lines == [
            "Date,Type,Name,Detail,In,Out",
            "2026-08-20,Sale,TCGplayer,no cards recorded,15.05,",
            "2026-08-17,Purchase,\"Game Grid, Inc\",,,193.39",
            ",Grading,PSA grading,no cards attached,,20.00",
        ])
    }

    // MARK: - Search

    private func row(_ title: String, _ detail: String = "", cents: Int) -> LedgerEntry {
        LedgerEntry(kind: .purchase(UUID()), date: day("2026-09-01"), title: title, detail: detail, amountCents: cents)
    }

    @Test func anEmptySearchKeepsEverything() {
        let search = LedgerSearch("   ")
        #expect(search.isEmpty)
        #expect(search.keeps(row("NovaTCG", cents: -32_450)))
    }

    @Test func aVendorMatchesWhateverHeCapitalises() {
        let entry = row("NovaTCG", cents: -32_450)
        #expect(LedgerSearch("novatcg").keeps(entry))
        #expect(LedgerSearch("nova").keeps(entry))
        #expect(LedgerSearch("TCG").keeps(entry))
        #expect(LedgerSearch("gamecraft").keeps(entry) == false)
    }

    @Test func theNoteIsSearchableToo() {
        let entry = row("NovaTCG", "4 cards · two PSA 10 slabs", cents: -32_450)
        #expect(LedgerSearch("slabs").keeps(entry))
    }

    @Test func anAmountMatchesFromTheFront() {
        let entry = row("NovaTCG", cents: -32_450)
        #expect(LedgerSearch("324").keeps(entry))
        #expect(LedgerSearch("324.50").keeps(entry))
        #expect(LedgerSearch("$324.50").keeps(entry))
        #expect(LedgerSearch("324.5").keeps(entry))
        // The middle of the amount is not a match: "45" would otherwise drag
        // in every row whose cents happen to read 45.
        #expect(LedgerSearch("45").keeps(entry) == false)
    }

    @Test func aDollarSignAndCommasAreNotTyping() {
        let entry = row("Gamecraft", cents: -125_000)
        #expect(LedgerSearch("$1,250").keeps(entry))
        #expect(LedgerSearch("1250").keeps(entry))
    }

    @Test func moneyInIsSearchedByItsAmountNotItsSign() {
        let sale = LedgerEntry(kind: .sale(UUID()), date: day("2026-09-02"), title: "TCGplayer", detail: "1 card", amountCents: 1_515)
        #expect(LedgerSearch("15.15").keeps(sale))
    }

    @Test func aNameThatLooksNumericStillSearchesText() {
        let entry = row("2026 Prize Pack", cents: -1_000)
        #expect(LedgerSearch("2026").keeps(entry))
        #expect(LedgerSearch("prize").keeps(entry))
    }

    @Test func dollarsKeepEveryCent() {
        #expect(LedgerExport.dollars(0) == "0.00")
        #expect(LedgerExport.dollars(5) == "0.05")
        #expect(LedgerExport.dollars(19_339) == "193.39")
    }
}
