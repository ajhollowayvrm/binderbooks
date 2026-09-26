import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// A receipt is read into a draft, the draft fills the Add sheet, and the
/// receipt is stored on its entry and travels in the backup.
@Suite struct ReceiptTests {
    private let now = ISO8601DateFormatter().date(from: "2026-09-25T18:00:00Z")!

    private func day(_ date: Date?) -> String? {
        guard let date else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: - Parser

    @Test func aPaperStoreReceiptReadsItsTotalTaxAndDate() {
        let lines = [
            "Walmart",
            "Save money. Live better.",
            "ST# 01234 OP# 009 TE# 12",
            "POKEMON ETB 052000123456 49.97 X",
            "POKEMON BOOSTER 052000123457 4.47 X",
            "SUBTOTAL 54.44",
            "TAX 1 7.250 % 3.95",
            "TOTAL 58.39",
            "VISA TEND 58.39",
            "CHANGE DUE 0.00",
            "09/14/26 14:33:02",
        ]
        let draft = ReceiptParser.parse(lines, now: now)
        #expect(draft.vendor == "Walmart")
        #expect(draft.totalCents == 5_839)
        #expect(draft.subtotalCents == 5_444)
        #expect(draft.taxCents == 395)
        #expect(day(draft.date) == "2026-09-14")
        #expect(!draft.looksLikeGrading)

        let fields = draft.purchaseFields
        #expect(fields?.itemCents == 5_444)
        #expect(fields?.taxCents == 395)
        #expect(fields?.shippingCents == 0)
    }

    /// An order page puts the amount on the row under its label.
    @Test func anOrderScreenshotTakesTheAmountOnTheNextRow() {
        let lines = [
            "Order Details",
            "Ordered on September 20, 2026",
            "Order# 112-1234567-7654321",
            "Item(s) Subtotal:",
            "$39.98",
            "Shipping & Handling:",
            "$5.99",
            "Total before tax:",
            "$45.97",
            "Estimated tax to be collected:",
            "$3.33",
            "Grand Total:",
            "$49.30",
            "Sold by: Amazon.com Services LLC",
        ]
        let draft = ReceiptParser.parse(lines, now: now)
        #expect(draft.vendor == "Amazon")
        #expect(draft.totalCents == 4_930)
        #expect(draft.subtotalCents == 3_998)
        #expect(draft.shippingCents == 599)
        #expect(draft.taxCents == 333)
        #expect(day(draft.date) == "2026-09-20")
    }

    /// The total is the fact. A discount the parser does not see comes off
    /// the item cost, so the landed cost still equals what he paid.
    @Test func theLandedCostEqualsTheTotalWhenTheLinesDoNotAddUp() {
        let lines = [
            "TCGplayer Order Confirmation",
            "Subtotal $100.00",
            "Coupon -$10.00",
            "Shipping $4.99",
            "Sales Tax $7.25",
            "Order Total $102.24",
        ]
        let draft = ReceiptParser.parse(lines, now: now)
        #expect(draft.vendor == "TCGplayer")
        let fields = draft.purchaseFields
        #expect(fields?.itemCents == 9_000)
        #expect(fields?.shippingCents == 499)
        #expect(fields?.taxCents == 725)
        #expect((fields?.itemCents ?? 0) + (fields?.shippingCents ?? 0) + (fields?.taxCents ?? 0) == 10_224)
    }

    /// The text PDFKit gives for a real PDF: close rows joined on one line.
    @Test func rowsThatAPDFJoinsStillReadApart() {
        let text = "TCGplayer Order Confirmation Order placed September 21, 2026 Subtotal $100.00\nShipping $4.99 Sales Tax $7.25\nOrder Total $112.24"
        let draft = ReceiptParser.parse(text.components(separatedBy: "\n"), now: now)
        #expect(draft.vendor == "TCGplayer")
        #expect(draft.subtotalCents == 10_000)
        #expect(draft.shippingCents == 499)
        #expect(draft.taxCents == 725)
        #expect(draft.totalCents == 11_224)
        #expect(day(draft.date) == "2026-09-21")
        #expect(ReceiptParser.segments(["Qty 2 @ 4.99 9.98 each"]) == ["Qty 2 @ 4.99", "9.98 each"])
    }

    @Test func aGraderInvoiceIsAGradingCharge() {
        let lines = [
            "PSA",
            "Invoice",
            "Submission #12345678",
            "Value Bulk x 10 $249.90",
            "Return Shipping $20.00",
            "Total Paid $269.90",
            "Aug 30, 2026",
        ]
        let draft = ReceiptParser.parse(lines, now: now)
        #expect(draft.vendor == "PSA")
        #expect(draft.looksLikeGrading)
        #expect(draft.gradingFields?.feesCents == 24_990)
        #expect(draft.gradingFields?.shippingCents == 2_000)
        #expect(day(draft.date) == "2026-08-30")
    }

    /// "tag" in "price tag" is not the grader TAG.
    @Test func aShortVendorNameMatchesOnlyInCapitals() {
        let draft = ReceiptParser.parse(["Corner Hobby Shop", "Keep the price tag", "Total 12.00"], now: now)
        #expect(draft.vendor == "Corner Hobby Shop")
        #expect(!draft.looksLikeGrading)
    }

    /// A store he has used before gets the ledger's spelling.
    @Test func aVendorOnTheLedgerIsFound() {
        let draft = ReceiptParser.parse(["THANK YOU FOR SHOPPING", "at GAMECRAFT", "Total $54.00"], knownVendors: ["Gamecraft"], now: now)
        #expect(draft.vendor == "Gamecraft")
        #expect(draft.expenseCents == 5_400)
    }

    @Test func freeShippingIsZeroAndATimeIsNotADate() {
        let draft = ReceiptParser.parse(["Target", "Shipping FREE", "Total $21.39", "14:33"], now: now)
        #expect(draft.shippingCents == 0)
        #expect(draft.date == nil)
        #expect(draft.totalCents == 2_139)
    }

    @Test func aStateTaxAndACityTaxAddUp() {
        let draft = ReceiptParser.parse(["State tax 1.50", "City tax 0.25", "Total 21.75"], now: now)
        #expect(draft.taxCents == 175)
    }

    @Test func thousandsReadAsOneAmount() {
        #expect(ReceiptParser.amounts(in: "Order Total: $1,249.00") == [124_900])
        #expect(ReceiptParser.amounts(in: "Qty 2 @ 4.99 9.98") == [499, 998])
    }

    @Test func nothingReadableGivesNoFields() {
        let draft = ReceiptParser.parse(["blurry", "?"], now: now)
        #expect(draft.totalCents == nil)
        #expect(draft.purchaseFields == nil)
        #expect(draft.gradingFields == nil)
        #expect(draft.expenseCents == nil)
    }

    // MARK: - Rows

    @Test func boxesOnOneRowJoinLeftToRight() {
        let rows = ReceiptParser.rows([
            .init(text: "$58.39", minX: 0.8, midY: 0.502, height: 0.02),
            .init(text: "TOTAL", minX: 0.1, midY: 0.5, height: 0.02),
            .init(text: "Walmart", minX: 0.3, midY: 0.05, height: 0.04),
            .init(text: "TAX", minX: 0.1, midY: 0.47, height: 0.02),
        ])
        #expect(rows == ["Walmart", "TAX", "TOTAL $58.39"])
    }

    // MARK: - Store

    @MainActor private func store() throws -> ModelContainer {
        try CollectionStore.container(inMemory: true)
    }

    @Test @MainActor func aReceiptGoesWithItsPurchase() throws {
        let container = try store()
        let context = container.mainContext
        let purchase = Purchase(vendor: "Walmart", itemCostCents: 5_444)
        context.insert(purchase)
        ReceiptOwner.purchase(purchase).attach([ReceiptFile(kind: .image, data: Data([1, 2, 3]), text: "TOTAL 58.39")], context: context)

        #expect(purchase.receipts.count == 1)
        let entry = LedgerEntry.entries(purchases: [purchase], grading: [], sales: []).first
        #expect(entry?.hasReceipt == true)

        context.delete(purchase)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<Receipt>()).isEmpty)
    }

    /// A card shows its purchase's receipts. A pull from a ripped pack finds
    /// the purchase through the pack's line.
    @Test @MainActor func aCardFindsItsPurchaseThroughARippedPack() throws {
        let container = try store()
        let context = container.mainContext
        let purchase = Purchase(vendor: "Target", itemCostCents: 4_999)
        let box = PurchaseItem(productId: 1, isSealed: true)
        let pack = PurchaseItem(productId: 2)
        context.insert(purchase)
        context.insert(box)
        context.insert(pack)
        box.purchase = purchase
        pack.parentItem = box
        let sealed = OwnedCard(productId: 1, printing: "", condition: "Near Mint", confidence: .manual)
        let pull = OwnedCard(productId: 3, printing: "", condition: "Near Mint", confidence: .manual)
        let loose = OwnedCard(productId: 4, printing: "", condition: "Near Mint", confidence: .manual)
        [sealed, pull, loose].forEach(context.insert)
        sealed.sourceItem = box
        pull.sourceItem = pack
        try context.save()

        #expect(sealed.purchase?.id == purchase.id)
        #expect(pull.purchase?.id == purchase.id)
        #expect(loose.purchase == nil)
    }

    /// Store credit paid for all of it. The cards come in at $0.
    @Test @MainActor func aZeroPurchasePutsItsCardsAtZero() throws {
        let container = try store()
        let context = container.mainContext
        let purchase = Purchase(vendor: "Gamecraft", note: "Store credit", itemCostCents: 0)
        context.insert(purchase)
        let lines = [PurchaseIntake.Line(productId: 1, name: "Booster Box", setName: "Set", isSealed: true, quantity: 2)]
        let cards = PurchaseIntake.record(lines, on: purchase, since: .distantPast, marketCents: { _ in 14_000 }, context: context)
        try context.save()
        #expect(cards.count == 2)
        #expect(cards.allSatisfy { $0.acquisitionBasisCents == 0 })
        #expect(purchase.landedCostCents == 0)
    }

    @Test @MainActor func receiptsSurviveTheExportRoundTrip() throws {
        let source = try store()
        let target = try store()
        let context = source.mainContext

        let purchase = Purchase(vendor: "Amazon", itemCostCents: 3_998)
        let expense = BusinessExpense(category: "Supplies", vendor: "Ultra PRO", amountCents: 1_299)
        let grading = GradingSubmission(graderRaw: "PSA", gradingFeesCents: 24_990)
        context.insert(purchase)
        context.insert(expense)
        context.insert(grading)
        ReceiptOwner.purchase(purchase).attach([ReceiptFile(kind: .pdf, data: Data("pdf".utf8), fileName: "invoice.pdf", text: "Grand Total $49.30")], context: context)
        ReceiptOwner.expense(expense).attach([ReceiptFile(kind: .image, data: Data([9, 9]))], context: context)
        ReceiptOwner.grading(grading).attach([ReceiptFile(kind: .image, data: Data([7]))], context: context)

        let file = try CollectionExport.decode(try CollectionExport.exportData(context))
        #expect(file.receipts?.count == 3)

        let report = try CollectionExport.apply(file, to: target.mainContext, mode: .replace)
        #expect(report.receipts == 3)
        let restored = try target.mainContext.fetch(FetchDescriptor<Purchase>()).first
        #expect(restored?.receipts.first?.fileName == "invoice.pdf")
        #expect(restored?.receipts.first?.kind == .pdf)
        #expect(restored?.receipts.first?.data == Data("pdf".utf8))
        #expect(try target.mainContext.fetch(FetchDescriptor<BusinessExpense>()).first?.receipts.count == 1)
        #expect(try target.mainContext.fetch(FetchDescriptor<GradingSubmission>()).first?.receipts.count == 1)

        let fixed = Date(timeIntervalSinceReferenceDate: 0)
        #expect(try CollectionExport.exportData(target.mainContext, now: fixed) == CollectionExport.exportData(context, now: fixed))
    }

    /// A version 10 file has no receipts key. It must still import.
    @Test @MainActor func aFileFromBeforeReceiptsStillImports() throws {
        let json = #"{"format":"cardtracker-collection","version":10,"exportedAt":"2026-09-25T00:00:00Z","purchases":[],"purchaseItems":[],"cards":[],"sessions":[]}"#
        let file = try CollectionExport.decode(Data(json.utf8))
        #expect(file.receipts == nil)
        // The container must outlive the call. A released container leaves
        // its context dead, and SwiftData traps on it.
        let container = try store()
        let report = try CollectionExport.apply(file, to: container.mainContext, mode: .merge)
        #expect(report.receipts == 0)
    }
}
