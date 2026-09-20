import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// The Sets browser: which sets a typed needle keeps, and how many cards of a
/// set he holds. The view is a list over these three functions.
@Suite @MainActor struct SetBrowserTests {
    private func summary(_ groupId: Int, _ name: String, _ abbreviation: String?, category: String = "Pokemon") -> SetSummary {
        SetSummary(groupId: groupId, categoryId: 3, categoryName: category, name: name,
                   abbreviation: abbreviation, publishedOn: nil, productCount: 140)
    }

    private var sets: [SetSummary] {
        [
            summary(24451, "ME: Mega Evolution Promo", "MEP"),
            summary(24380, "ME01: Mega Evolution", "MEG"),
            summary(100, "SV03: Obsidian Flames", "OBF"),
            summary(104, "Timeless Bonds", "BT-26", category: "Digimon Card Game"),
        ]
    }

    /// The catalog hits the inventory cache would hold: product 1 and 2 are in
    /// Mega Evolution Promo, product 9 is in Obsidian Flames.
    private var hits: [Int: SearchHit] {
        func hit(_ productId: Int, _ groupId: Int) -> SearchHit {
            SearchHit(productId: productId, groupId: groupId, categoryId: 3, name: "Card \(productId)",
                      cleanName: "card \(productId)", setName: "Set \(groupId)", isSealed: false, printingCount: 1)
        }
        return [1: hit(1, 24451), 2: hit(2, 24451), 9: hit(9, 100)]
    }

    private func store() throws -> ModelContainer {
        try CollectionStore.container(inMemory: true)
    }

    // MARK: - Held counts

    /// Nine copies of one card is one card of the set filled. The row says how
    /// much of the set he has, not how many pieces of cardboard.
    @Test func aCountIsDistinctCardsNotCopies() throws {
        let container = try store()
        for _ in 0..<9 {
            container.mainContext.insert(OwnedCard(productId: 1, printing: "Normal", condition: CardCondition.nearMint.rawValue, confidence: .manual))
        }
        container.mainContext.insert(OwnedCard(productId: 2, printing: "Normal", condition: CardCondition.nearMint.rawValue, confidence: .manual))
        let cards = try container.mainContext.fetch(FetchDescriptor<OwnedCard>())

        #expect(SetBrowser.heldCounts(cards: cards, hits: hits) == [24451: 2])
    }

    /// A set he holds nothing from is absent, never a zero. The row can then
    /// tell "none" from "the cache has not loaded", and it draws neither.
    @Test func aSetHeHoldsNothingFromIsAbsent() throws {
        let container = try store()
        container.mainContext.insert(OwnedCard(productId: 1, printing: "Normal", condition: CardCondition.nearMint.rawValue, confidence: .manual))
        let cards = try container.mainContext.fetch(FetchDescriptor<OwnedCard>())

        let counts = SetBrowser.heldCounts(cards: cards, hits: hits)
        #expect(counts[100] == nil)
        #expect(counts[24380] == nil)
    }

    /// The same predicate the checklist uses, so the row and the set it opens
    /// never disagree. A sold, lost, or sealed card is not held.
    @Test func soldLostAndSealedCardsDoNotCount() throws {
        let container = try store()
        func card(_ productId: Int, _ configure: (OwnedCard) -> Void) {
            let c = OwnedCard(productId: productId, printing: "Normal", condition: CardCondition.nearMint.rawValue, confidence: .manual)
            configure(c)
            container.mainContext.insert(c)
        }
        card(1) { _ in }
        card(2) { $0.status = .sold }
        card(9) { $0.status = .lost }
        let cards = try container.mainContext.fetch(FetchDescriptor<OwnedCard>())

        #expect(SetBrowser.heldCounts(cards: cards, hits: hits) == [24451: 1])
    }

    /// A card the catalog cache has not resolved yet belongs to no set. It must
    /// not land in a bucket of its own.
    @Test func aCardWithNoCatalogHitCountsNowhere() throws {
        let container = try store()
        container.mainContext.insert(OwnedCard(productId: 777, printing: "Normal", condition: CardCondition.nearMint.rawValue, confidence: .manual))
        let cards = try container.mainContext.fetch(FetchDescriptor<OwnedCard>())

        #expect(SetBrowser.heldCounts(cards: cards, hits: hits).isEmpty)
    }

    // MARK: - Filtering

    @Test func aSetIsFoundByItsCodeOrItsName() {
        #expect(SetBrowser.visible(sets, query: "MEP").map(\.groupId) == [24451])
        #expect(SetBrowser.visible(sets, query: "mep").map(\.groupId) == [24451])
        #expect(SetBrowser.visible(sets, query: "mega evolution").map(\.groupId) == [24451, 24380])
        #expect(SetBrowser.visible(sets, query: "obsidian").map(\.groupId) == [100])
    }

    @Test func anEmptyQueryKeepsEverySet() {
        #expect(SetBrowser.visible(sets, query: "   ").count == sets.count)
    }

    // MARK: - Grouping

    /// He owns one kind of card. The rest are in the catalog because TCGplayer
    /// carries them, and they should not be in the way.
    @Test func pokemonComesFirstAndTheRestKeepTheirOrder() {
        let groups = SetBrowser.grouped(sets)
        #expect(groups.map(\.category) == ["Pokemon", "Digimon Card Game"])
        #expect(groups.first?.sets.count == 3)
    }
}
