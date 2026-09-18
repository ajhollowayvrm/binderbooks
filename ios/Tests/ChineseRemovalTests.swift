import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// Simplified Chinese was dropped on 2026-09-17, and its cards go once.
@Suite struct ChineseRemovalTests {
    @MainActor private func card(_ context: ModelContext, productId: Int, on item: PurchaseItem? = nil) -> OwnedCard {
        let card = OwnedCard(productId: productId, printing: "Normal", condition: CardCondition.nearMint.rawValue, confidence: .manual)
        card.sourceItem = item
        context.insert(card)
        return card
    }

    @Test @MainActor func onlyTheChineseCardsGoAndThePurchaseKeepsItsCost() throws {
        let container = try CollectionStore.container(inMemory: true)
        let context = container.mainContext
        let defaults = try #require(UserDefaults(suiteName: "ChineseRemovalTests-\(UUID().uuidString)"))

        let purchase = Purchase(vendor: "Card show", itemCostCents: 4_000)
        context.insert(purchase)
        let line = PurchaseItem(productId: 1_118_691_963, quantity: 2)
        line.purchase = purchase
        line.allocatedCostCents = 4_000
        context.insert(line)
        _ = [card(context, productId: 1_118_691_963, on: line), card(context, productId: 1_904_763_509, on: line)]
        let english = card(context, productId: 709_971)
        let aboveTheRange = card(context, productId: 2_000_000_000)
        try context.save()

        ChineseRemoval.run(context, defaults: defaults)

        let left = try context.fetch(FetchDescriptor<OwnedCard>())
        #expect(Set(left.map(\.id)) == [english.id, aboveTheRange.id])
        #expect(purchase.landedCostCents == 4_000)
        #expect(line.allocatedCostCents == 4_000)
        #expect(defaults.bool(forKey: ChineseRemoval.key))

        // Once only: a card that arrives later in the range stays.
        let later = card(context, productId: 1_500_000_000)
        try context.save()
        ChineseRemoval.run(context, defaults: defaults)
        #expect(try context.fetch(FetchDescriptor<OwnedCard>()).contains { $0.id == later.id })
        #expect(try context.fetch(FetchDescriptor<OwnedCard>()).count == 3)
    }
}
