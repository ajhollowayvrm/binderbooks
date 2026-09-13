import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// Every record on the books takes an edit after it is saved. These cover the
/// edits with rules: a purchase split, a card's cost, a grading split, and a
/// card's catalog product.
@Suite struct RecordEditorTests {
    @MainActor private func store() throws -> ModelContainer {
        try CollectionStore.container(inMemory: true)
    }

    private let bought = Date(timeIntervalSince1970: 1_780_000_000)

    /// A $10.00 purchase with two cards, each on its own line, each $5.00 by the split.
    @MainActor private func purchase(_ context: ModelContext) throws -> (Purchase, OwnedCard, OwnedCard) {
        let purchase = Purchase(date: bought, vendor: "Gamecraft", itemCostCents: 1_000)
        context.insert(purchase)
        var cards: [OwnedCard] = []
        for _ in 0..<2 {
            let item = PurchaseItem(productId: 42)
            item.purchase = purchase
            context.insert(item)
            let card = OwnedCard(productId: 42, printing: "Normal", condition: CardCondition.nearMint.rawValue, confidence: .manual)
            card.sourceItem = item
            card.acquiredAt = bought
            context.insert(card)
            cards.append(card)
        }
        try context.save()
        Allocation.allocate(purchase)
        Allocation.writeCardBases(purchase)
        try context.save()
        return (purchase, cards[0], cards[1])
    }

    @Test @MainActor func aNewTotalSplitsAgainAndTheCardsMoveWithTheDate() throws {
        let container = try store()
        let context = container.mainContext
        let (purchase, a, b) = try purchase(context)
        #expect(a.acquisitionBasisCents == 500)

        var details = PurchaseEditor.Details(purchase)
        details.itemCostCents = 2_000
        details.date = bought.addingTimeInterval(86_400)
        details.vendor = " Fuzzy's "
        let resplit = try PurchaseEditor.apply(details, to: purchase, context: context)

        #expect(resplit)
        #expect(purchase.vendor == "Fuzzy's")
        #expect(a.acquisitionBasisCents == 1_000)
        #expect(b.acquisitionBasisCents == 1_000)
        #expect(a.acquiredAt == details.date)
    }

    /// The seed import wrote a real cost on its cards and marked none manual.
    @Test @MainActor func aCostTheImportWroteIsNotOverwritten() throws {
        let container = try store()
        let context = container.mainContext
        let (purchase, a, b) = try purchase(context)
        b.basisIsAllocated = false
        b.acquisitionBasisCents = 800
        try context.save()

        var details = PurchaseEditor.Details(purchase)
        details.itemCostCents = 2_000
        let resplit = try PurchaseEditor.apply(details, to: purchase, context: context)

        #expect(!resplit)
        #expect(a.acquisitionBasisCents == 500)
        #expect(b.acquisitionBasisCents == 800)
    }

    @Test @MainActor func aTypedCostComesOutOfThePurchaseAndCanGoBackToTheSplit() throws {
        let container = try store()
        let context = container.mainContext
        let (_, a, b) = try purchase(context)

        var details = CardEditor.CostDetails(a)
        #expect(details.usesSplit)
        details.usesSplit = false
        details.acquisitionBasisCents = 700
        try CardEditor.apply(details, to: a, context: context)

        #expect(a.acquisitionBasisCents == 700)
        #expect(a.basisIsManual)
        #expect(b.acquisitionBasisCents == 300)

        details = CardEditor.CostDetails(a)
        details.usesSplit = true
        try CardEditor.apply(details, to: a, context: context)

        #expect(!a.basisIsManual)
        #expect(a.acquisitionBasisCents == 500)
        #expect(b.acquisitionBasisCents == 500)
    }

    @Test @MainActor func aDateChangeAloneDoesNotTurnASplitIntoATypedCost() throws {
        let container = try store()
        let context = container.mainContext
        let (_, a, _) = try purchase(context)

        var details = CardEditor.CostDetails(a)
        details.acquiredAt = bought.addingTimeInterval(3_600)
        try CardEditor.apply(details, to: a, context: context)

        #expect(a.acquiredAt == details.acquiredAt)
        #expect(!a.basisIsManual)
        #expect(a.basisIsAllocated)
    }

    @Test @MainActor func aNewGradingTotalLandsOnTheCardsAndANumberChangeDoesNot() throws {
        let container = try store()
        let context = container.mainContext
        let (_, a, b) = try purchase(context)
        let submission = GradingSubmission(graderRaw: "psa")
        context.insert(submission)
        context.insert(GradingEntry(submission: submission, card: a))
        context.insert(GradingEntry(submission: submission, card: b))
        try context.save()

        var details = GradingEditor.Details(submission)
        details.gradingFeesCents = 3_000
        try GradingEditor.apply(details, to: submission, context: context)

        #expect(a.gradingBasisCents == 1_500)
        #expect(b.gradingBasisCents == 1_500)

        a.gradingBasisCents = 1_999
        details = GradingEditor.Details(submission)
        details.submissionNumber = " 12345678 "
        try GradingEditor.apply(details, to: submission, context: context)

        #expect(submission.submissionNumber == "12345678")
        #expect(a.gradingBasisCents == 1_999)
    }

    @Test @MainActor func anExpenseTakesItsEdit() throws {
        let container = try store()
        let context = container.mainContext
        let expense = BusinessExpense(vendor: "Amazon", amountCents: 1_299)
        context.insert(expense)
        try context.save()

        var details = ExpenseEditor.Details(expense)
        details.amountCents = 1_499
        details.category = " Supplies "
        try ExpenseEditor.apply(details, to: expense, context: context)

        #expect(expense.amountCents == 1_499)
        #expect(expense.category == "Supplies")
    }

    @Test @MainActor func aHandEnteredCardFoundInTheCatalogLosesItsTypedIdentity() throws {
        let container = try store()
        let context = container.mainContext
        let card = OwnedCard(productId: 0, printing: "", condition: CardCondition.nearMint.rawValue, confidence: .manual)
        card.manualName = "Pikachu"
        card.manualNumber = "025/165"
        card.manualMarketCents = 300
        card.language = "it"
        card.skuId = 7
        context.insert(card)
        try context.save()

        try CardEditor.assign(card, toProduct: 99, context: context)

        #expect(card.productId == 99)
        #expect(card.manualName.isEmpty)
        #expect(card.manualNumber.isEmpty)
        #expect(card.manualMarketCents == nil)
        #expect(card.language == "en")
        #expect(card.skuId == nil)
        #expect(card.candidateProductIds.first == 99)
    }
}
