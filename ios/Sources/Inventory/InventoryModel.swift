import Foundation
import Observation

/// One inventory line: the card, its catalog row, and its market value.
struct InventoryRow: Identifiable {
    var card: OwnedCard
    var hit: SearchHit?
    var marketCents: Int?

    var id: UUID { card.id }

    /// Market minus what the card cost. A basis split out of a pack or a lot
    /// counts: he prices a card from what the item cost, and reads the
    /// difference when he sells it. `basisIsAllocated` still says the figure
    /// was derived, but it no longer hides it (his call, 2026-09-10; it
    /// overrides the `docs/04` rule).
    ///
    /// Nil when there is no market price or no cost, because market minus
    /// nothing is not a gain.
    ///
    /// A graded card counts against what the slab is worth, not the raw
    /// price: he paid the acquisition and the grading fee, and a PSA 10 is
    /// not the card the catalog prices.
    var unrealizedCents: Int? {
        guard !card.isBulk, card.totalBasisCents > 0, let value = gradedValueCents ?? marketCents else { return nil }
        return value - card.totalBasisCents
    }

    /// What the slab is worth at the grade it came back at. Nil while the
    /// grade is unknown, or when he has entered no figure for that grade.
    var gradedValueCents: Int? {
        GradedComps.value(grader: card.graderRaw, grade: card.gradeLabel, in: card.effectiveCompCents)
    }

    /// The grader the card is out at, from its "at PSA" / "at CGC" label.
    var graderAtGrader: String? { GradedComps.graderAtGrader(tags: card.tags) }

    /// What the card might come back worth: lowest to highest of the comps he
    /// entered for the grader it is at. Nil when it is home, or when he has
    /// entered no comps for that grader.
    var projectedRange: ClosedRange<Int>? {
        guard let grader = graderAtGrader else { return nil }
        return GradedComps.range(for: grader, in: card.effectiveCompCents)
    }

    /// The figure the row leads with. A known grade wins, then a projection
    /// for a card still out, then the catalog's raw price. In every case the
    /// row shows the number that answers "what is this worth now".
    var priceText: String {
        if let value = gradedValueCents { return value.asCurrency }
        if let range = projectedRange { return GradedComps.rangeText(range) }
        return marketCents?.asCurrency ?? "—"
    }
}

struct InventoryFilter: Equatable {
    var confidences: Set<MatchConfidence> = []
    var groupId: Int?
    var slabsOnly = false
    var hideBulk = false
    var personalOnly = false
    /// A sold card left inventory. It stays out of the page unless he asks.
    var showSold = false
    /// `TagKey` values, not display forms. A card matches when it holds any of
    /// them, which is what "binder 3" plus "for sale" means to him.
    var tagKeys: Set<String> = []

    /// True when a chip is on. The typed query is not part of this, because the
    /// search header owns the query and the Clear button must not wipe it.
    var isActive: Bool {
        !confidences.isEmpty || groupId != nil || slabsOnly || hideBulk || personalOnly || showSold || !tagKeys.isEmpty
    }
}

struct InventorySummary: Equatable {
    var cardCount = 0
    var marketCents = 0
    var basisCents = 0
    /// Market and basis over the cards that carry both, so the difference is a
    /// comparison of like with like.
    var pricedMarketCents = 0
    var pricedBasisCents = 0
    /// How many of those costs were split out of a purchase rather than paid
    /// for one card. Reported, not deducted.
    var allocatedCount = 0

    var unrealizedCents: Int { pricedMarketCents - pricedBasisCents }
}

/// Joins committed cards to the catalog and serves the filtered list.
@MainActor
@Observable
final class InventoryModel {
    var filter = InventoryFilter()
    private(set) var hits: [Int: SearchHit] = [:]
    private(set) var prices: [Int: [ProductPrice]] = [:]
    private(set) var isLoading = false

    var database: @MainActor () -> CatalogDatabase? = { nil }
    /// The catalog the caches were built from. A swap invalidates them.
    var catalogPath: String?

    /// Committed cards only, newest first. The caller passes the store's cards.
    ///
    /// `query` is the text from the one search field. The order stays
    /// acquisition-first even with a query, because he reads his own inventory
    /// in that order everywhere else.
    /// `applyFilter` is false for the collection section of a search, so the
    /// chips on the inventory page never narrow a search result in silence.
    func rows(from cards: [OwnedCard], query: String = "", applyFilter: Bool = true) -> [InventoryRow] {
        let parsed = OwnedCardQuery(query)
        return cards
            .filter { $0.isCommitted && (!applyFilter || matches($0)) && matchesQuery($0, parsed) }
            .sorted { $0.acquiredAt == $1.acquiredAt ? $0.scannedAt > $1.scannedAt : $0.acquiredAt > $1.acquiredAt }
            .map { InventoryRow(card: $0, hit: hits[$0.productId], marketCents: marketCents(for: $0)) }
    }

    /// Labels in use, most used first. Derived on every read, so a deleted card
    /// drops out of the suggestions at once.
    func tagUses(in cards: [OwnedCard]) -> [TagUse] {
        CardTagIndex.uses(in: cards.filter(\.isCommitted))
    }

    func summary(of rows: [InventoryRow]) -> InventorySummary {
        var s = InventorySummary()
        for row in rows {
            s.cardCount += max(1, row.card.quantity)
            let market = (row.marketCents ?? 0) * max(1, row.card.quantity)
            s.marketCents += market
            s.basisCents += row.card.totalBasisCents
            if row.card.basisIsAllocated { s.allocatedCount += 1 }
            if !row.card.isBulk, row.marketCents != nil, row.card.totalBasisCents > 0 {
                s.pricedMarketCents += market
                s.pricedBasisCents += row.card.totalBasisCents
            }
        }
        return s
    }

    /// Sets that appear in inventory, for the set chip.
    func sets(in cards: [OwnedCard], from all: [SetSummary]) -> [SetSummary] {
        let groupIds = Set(cards.compactMap { hits[$0.productId]?.groupId })
        return all.filter { groupIds.contains($0.groupId) }
    }

    func marketCents(for card: OwnedCard) -> Int? {
        guard let rows = prices[card.productId], !rows.isEmpty else { return nil }
        if let exact = rows.first(where: { $0.subTypeName == card.printing })?.marketCents { return exact }
        return rows.compactMap(\.marketCents).min()
    }

    func load(for cards: [OwnedCard]) async {
        guard let db = database() else { return }
        let ids = Array(Set(cards.map(\.productId).filter { $0 > 0 }))
        let missingHits = ids.filter { hits[$0] == nil }
        let missingPrices = ids.filter { prices[$0] == nil }
        guard !missingHits.isEmpty || !missingPrices.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        let search = CatalogSearch(database: db)
        if !missingHits.isEmpty, let rows = try? await search.hits(ids: missingHits) {
            for row in rows { hits[row.productId] = row }
        }
        if !missingPrices.isEmpty, let rows = try? await search.prices(for: missingPrices) {
            for id in missingPrices { prices[id] = rows[id] ?? [] }
        }
        // The new hits change what a card can match on.
        haystacks = [:]
    }

    /// Call after a tag edit, so the next query sees the new label.
    func invalidateHaystacks() {
        haystacks = [:]
    }

    /// Tests inject catalog rows without a database.
    func setTestRows(hits: [Int: SearchHit], prices: [Int: [ProductPrice]]) {
        self.hits = hits
        self.prices = prices
        haystacks = [:]
    }

    /// Drop cached rows after a catalog swap, so prices refresh.
    func invalidate() {
        hits = [:]
        prices = [:]
        haystacks = [:]
    }

    /// One cleaned string per card, built once. The match pass runs on every
    /// keystroke with no debounce, so it must not rebuild these.
    private var haystacks: [UUID: String] = [:]

    private func matchesQuery(_ card: OwnedCard, _ query: OwnedCardQuery) -> Bool {
        if query.isEmpty { return true }
        let hit = hits[card.productId]
        let haystack: String
        if let cached = haystacks[card.id] {
            haystack = cached
        } else {
            haystack = OwnedCardMatcher.haystack(card: card, hit: hit)
            haystacks[card.id] = haystack
        }
        return OwnedCardMatcher.matches(haystack: haystack, card: card, hit: hit, query: query)
    }

    private func matches(_ card: OwnedCard) -> Bool {
        if !filter.tagKeys.isEmpty, filter.tagKeys.isDisjoint(with: Set(card.tags.map(TagKey.of))) { return false }
        if !filter.confidences.isEmpty, !filter.confidences.contains(card.matchConfidence) { return false }
        if let groupId = filter.groupId, hits[card.productId]?.groupId != groupId { return false }
        if filter.slabsOnly, !card.isSlabbed { return false }
        if filter.hideBulk, card.isBulk { return false }
        if filter.personalOnly, !card.isPersonalCollection { return false }
        if !filter.showSold, CardTagIndex.has(ReservedTag.sold, on: card) { return false }
        return true
    }
}
