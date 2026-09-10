import Foundation
import Observation

/// One inventory line: the card, its catalog row, and its market value.
struct InventoryRow: Identifiable {
    var card: OwnedCard
    var hit: SearchHit?
    var marketCents: Int?

    var id: UUID { card.id }

    /// Market minus basis, only when the basis is real. An allocated basis is
    /// an artifact and never renders as a gain or a loss (docs/04).
    var unrealizedCents: Int? {
        guard !card.basisIsAllocated, !card.isBulk, let market = marketCents else { return nil }
        return market - card.totalBasisCents
    }
}

struct InventoryFilter: Equatable {
    var statuses: Set<CardStatus> = []
    var confidences: Set<MatchConfidence> = []
    var groupId: Int?
    var slabsOnly = false
    var hideBulk = false
    var personalOnly = false

    var isActive: Bool {
        !statuses.isEmpty || !confidences.isEmpty || groupId != nil || slabsOnly || hideBulk || personalOnly
    }
}

struct InventorySummary: Equatable {
    var cardCount = 0
    var marketCents = 0
    var basisCents = 0
    /// Market and basis over cards with a real, unallocated basis.
    var pricedMarketCents = 0
    var pricedBasisCents = 0
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
    func rows(from cards: [OwnedCard]) -> [InventoryRow] {
        cards
            .filter { $0.isCommitted && matches($0) }
            .sorted { $0.acquiredAt == $1.acquiredAt ? $0.scannedAt > $1.scannedAt : $0.acquiredAt > $1.acquiredAt }
            .map { InventoryRow(card: $0, hit: hits[$0.productId], marketCents: marketCents(for: $0)) }
    }

    func summary(of rows: [InventoryRow]) -> InventorySummary {
        var s = InventorySummary()
        for row in rows {
            s.cardCount += max(1, row.card.quantity)
            let market = (row.marketCents ?? 0) * max(1, row.card.quantity)
            s.marketCents += market
            s.basisCents += row.card.totalBasisCents
            if row.card.basisIsAllocated {
                s.allocatedCount += 1
            } else if !row.card.isBulk, row.marketCents != nil {
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
    }

    /// Tests inject catalog rows without a database.
    func setTestRows(hits: [Int: SearchHit], prices: [Int: [ProductPrice]]) {
        self.hits = hits
        self.prices = prices
    }

    /// Drop cached rows after a catalog swap, so prices refresh.
    func invalidate() {
        hits = [:]
        prices = [:]
    }

    private func matches(_ card: OwnedCard) -> Bool {
        if !filter.statuses.isEmpty, !filter.statuses.contains(card.status) { return false }
        if !filter.confidences.isEmpty, !filter.confidences.contains(card.matchConfidence) { return false }
        if let groupId = filter.groupId, hits[card.productId]?.groupId != groupId { return false }
        if filter.slabsOnly, card.certNumber == nil { return false }
        if filter.hideBulk, card.isBulk { return false }
        if filter.personalOnly, !card.isPersonalCollection { return false }
        return true
    }
}
