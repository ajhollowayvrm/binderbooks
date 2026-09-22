import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// Every record on the books takes an edit after it is saved. These cover the
/// edits with rules: a purchase, a grading charge, a card's catalog product,
/// and new cards added by hand. No edit changes a card's cost, because a card
/// has none.
@Suite struct RecordEditorTests {
    @MainActor private func store() throws -> ModelContainer {
        try CollectionStore.container(inMemory: true)
    }

    private let bought = Date(timeIntervalSince1970: 1_780_000_000)

    /// A $10.00 purchase with two cards, each on its own line. The links and
    /// the costs are old data, the shape an old import still brings in.
    @MainActor private func purchase(_ context: ModelContext) throws -> (Purchase, OwnedCard, OwnedCard) {
        let purchase = Purchase(date: bought, vendor: "Gamecraft", itemCostCents: 1_000)
        context.insert(purchase)
        var cards: [OwnedCard] = []
        for _ in 0..<2 {
            let item = PurchaseItem(productId: 42)
            item.purchase = purchase
            item.allocatedCostCents = 500
            context.insert(item)
            let card = OwnedCard(productId: 42, printing: "Normal", condition: CardCondition.nearMint.rawValue, confidence: .manual)
            card.sourceItem = item
            card.acquiredAt = bought
            card.acquisitionBasisCents = 500
            card.basisIsAllocated = true
            context.insert(card)
            cards.append(card)
        }
        try context.save()
        return (purchase, cards[0], cards[1])
    }

    @Test @MainActor func editingAPurchaseChangesNoCard() throws {
        let container = try store()
        let context = container.mainContext
        let (purchase, a, b) = try purchase(context)

        var details = PurchaseEditor.Details(purchase)
        details.itemCostCents = 2_000
        details.date = bought.addingTimeInterval(86_400)
        details.vendor = " Fuzzy's "
        try PurchaseEditor.apply(details, to: purchase, context: context)

        #expect(purchase.vendor == "Fuzzy's")
        #expect(purchase.landedCostCents == 2_000)
        #expect(purchase.date == details.date)
        #expect(a.acquiredAt == bought)
        #expect(b.acquiredAt == bought)
        #expect(a.acquisitionBasisCents == 500)
        #expect(b.acquisitionBasisCents == 500)
    }

    /// `PurchaseItem.cards` is a cascade relationship. The delete must remove
    /// the old links first, or the cards go with the purchase.
    @Test @MainActor func deletingAPurchaseKeepsTheCardsThatWereLinkedToIt() throws {
        let container = try store()
        let context = container.mainContext
        let (purchase, a, b) = try purchase(context)
        // A nested line, the shape an old rip left.
        let child = PurchaseItem(productId: 43)
        child.parentItem = purchase.items.first
        context.insert(child)
        let pulled = OwnedCard(productId: 43, printing: "Normal", condition: CardCondition.nearMint.rawValue, confidence: .manual)
        pulled.sourceItem = child
        context.insert(pulled)
        try context.save()

        try PurchaseEditor.delete(purchase, context: context)

        #expect(try context.fetchCount(FetchDescriptor<Purchase>()) == 0)
        let cards = try context.fetch(FetchDescriptor<OwnedCard>())
        #expect(Set(cards.map(\.id)) == [a.id, b.id, pulled.id])
        #expect(cards.allSatisfy { $0.sourceItem == nil })
    }

    @Test @MainActor func aNewGradingTotalChangesTheChargeAndNoCard() throws {
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
        details.submissionNumber = " 12345678 "
        try GradingEditor.apply(details, to: submission, context: context)

        #expect(submission.totalCostCents == 3_000)
        #expect(submission.submissionNumber == "12345678")
        #expect(a.gradingBasisCents == 0)
        #expect(b.gradingBasisCents == 0)
        #expect(submission.entries.allSatisfy { $0.allocatedFeeCents == 0 })
    }

    @Test @MainActor func addingACardNeverTouchesAPurchase() throws {
        let container = try store()
        let context = container.mainContext
        _ = try purchase(context)
        let purchases = try context.fetchCount(FetchDescriptor<Purchase>())
        let lines = try context.fetchCount(FetchDescriptor<PurchaseItem>())

        let added = CardEditor.addCards(
            productId: 7, isSealed: true, quantity: 3, printing: "",
            condition: CardCondition.nearMint.rawValue, context: context
        )
        let typed = CardEditor.addCards(
            productId: 0, isSealed: false, quantity: 1, printing: "",
            condition: CardCondition.nearMint.rawValue,
            manualName: " Pikachu ", manualMarketCents: 300, language: "it", context: context
        )

        #expect(added.count == 3)
        #expect(added.allSatisfy { $0.isSealedSelf && $0.sourceItem == nil && $0.acquisitionBasisCents == 0 })
        #expect(typed.first?.manualName == "Pikachu")
        #expect(typed.first?.language == "it")
        #expect(typed.first?.manualMarketCents == 300)
        #expect(try context.fetchCount(FetchDescriptor<Purchase>()) == purchases)
        #expect(try context.fetchCount(FetchDescriptor<PurchaseItem>()) == lines)
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
