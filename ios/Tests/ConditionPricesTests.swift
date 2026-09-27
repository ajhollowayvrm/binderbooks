import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// A card's prices follow its condition: TCGplayer's own SKU, not the
/// catalog's row for any condition.
@Suite struct ConditionPricesTests {
    /// One product, 509980, with a Near Mint and a Damaged Holofoil SKU.
    private struct StubPricing: TCGplayerSkuPricing {
        var refuse = false
        func details(productId: Int) async throws -> TCGplayerMarketClient.Details {
            if refuse { throw TCGplayerMarketClient.Failure.http(403) }
            return .init(productName: "Charizard ex", skus: [
                .init(skuId: 7_337_363, condition: "Near Mint", printing: "Holofoil", language: "English"),
                .init(skuId: 7_337_367, condition: "Damaged", printing: "Holofoil", language: "English"),
            ])
        }
        func marketPrices(skuIds: [Int]) async throws -> [Int: Int] {
            [7_337_363: 9_842, 7_337_367: 6_019].filter { skuIds.contains($0.key) }
        }
        func lowestPrice(productId: Int, condition: String, printing: String, language: String) async throws -> Int? {
            condition == "Damaged" ? 6_019 : 9_200
        }
    }

    private func key(_ condition: String) -> ConditionPrices.Key {
        .init(productId: 509_980, condition: condition, printing: "Holofoil", language: "English")
    }

    @Test @MainActor func eachConditionGetsItsOwnSkuPrices() async {
        let store = ConditionPrices()
        let priced = await store.fetch([key("Near Mint"), key("Damaged"), key("Lightly Played")], client: StubPricing(), pause: .zero)
        #expect(priced == 2)
        #expect(store.entry(for: key("Near Mint")) == .init(skuId: 7_337_363, marketCents: 9_842, lowCents: 9_200, fetchedAt: store.entry(for: key("Near Mint"))!.fetchedAt))
        #expect(store.entry(for: key("Damaged"))?.marketCents == 6_019)
        // TCGplayer has no Lightly Played SKU in the stub: remembered as none.
        #expect(store.entry(for: key("Lightly Played"))?.skuId == nil)
    }

    @Test @MainActor func aFreshEntryIsNotFetchedAgainAndAStaleOneIs() async {
        let store = ConditionPrices()
        let then = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(await store.fetch([key("Damaged")], client: StubPricing(), now: then, pause: .zero) == 1)
        #expect(await store.fetch([key("Damaged")], client: StubPricing(), now: then.addingTimeInterval(60), pause: .zero) == 0)
        #expect(await store.fetch([key("Damaged")], client: StubPricing(), now: then.addingTimeInterval(ConditionPrices.maxAge + 1), pause: .zero) == 1)
    }

    @Test @MainActor func aRefusalStoresNothing() async {
        let store = ConditionPrices()
        #expect(await store.fetch([key("Damaged")], client: StubPricing(refuse: true), pause: .zero) == 0)
        #expect(store.entry(for: key("Damaged")) == nil)
    }

    @Test @MainActor func theCardShowsItsConditionsPricesAndItsValueFollows() async throws {
        let container = try CollectionStore.container(inMemory: true)
        let card = OwnedCard(productId: 509_980, printing: "Holofoil", condition: "Near Mint", confidence: .manual)
        container.mainContext.insert(card)

        let model = InventoryModel()
        model.setTestRows(
            hits: [509_980: SearchHit(productId: 509_980, groupId: 1, categoryId: 3, name: "Charizard ex", cleanName: "charizard ex", setName: "Obsidian Flames", isSealed: false, printingCount: 1)],
            prices: [509_980: [ProductPrice(subTypeName: "Holofoil", marketCents: 9_994, asOf: "2026-09-17", lowCents: 7_675)]]
        )
        // Before a fetch: the catalog's row.
        #expect(model.tcgPrice(for: card)?.marketCents == 9_994)

        await model.conditionPrices.fetch([key("Near Mint"), key("Damaged")], client: StubPricing(), pause: .zero)
        #expect(model.tcgPrice(for: card)?.lowCents == 9_200)

        card.condition = "Damaged"
        #expect(model.tcgPrice(for: card)?.marketCents == 6_019)
        #expect(model.tcgPrice(for: card)?.lowCents == 6_019)
        #expect(model.marketCents(for: card) == 6_019)
    }
}
