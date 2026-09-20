import Foundation
import GRDB

/// One set as a checklist: every single in the set, once for each printing
/// TCGplayer prices. A master set is every slot filled.
///
/// A slot is a product and a printing, because a master set counts a reverse
/// holo as a separate card. A product with no price row has one slot with no
/// printing, so it still shows on the list.
struct MasterSet: Equatable, Sendable {
    struct Slot: Identifiable, Hashable, Sendable {
        var hit: SearchHit
        /// Nil only for a product with no price row.
        var printing: String?
        var marketCents: Int?
        /// Copies he holds in this printing.
        var ownedCount = 0
        /// Copies of this product with no printing set. They sit on the
        /// product's first slot and fill no slot, because the app cannot tell
        /// which printing they are.
        var unsetPrintingCount = 0

        var id: String { "\(hit.productId)|\(printing ?? "")" }
        var isOwned: Bool { ownedCount > 0 }
    }

    /// What the checklist needs to know about one owned card.
    struct OwnedCopy: Sendable {
        var productId: Int
        var printing: String
        var quantity: Int
    }

    var slots: [Slot]

    var ownedSlots: Int { slots.count(where: \.isOwned) }
    var missing: [Slot] { slots.filter { !$0.isOwned } }
    /// The market value of the slots he holds, one copy each.
    var ownedValueCents: Int { slots.filter(\.isOwned).compactMap(\.marketCents).reduce(0, +) }
    /// The market cost of one copy of every missing slot that has a price.
    var costToFinishCents: Int { missing.compactMap(\.marketCents).reduce(0, +) }
    /// Missing slots with no market price. The cost to finish leaves them out.
    var unpricedMissing: Int { missing.count(where: { $0.marketCents == nil }) }

    /// The cards that fill a slot. A sold or lost card does not. A card at the
    /// grader, a slab, a listed card, and a personal collection card do,
    /// because he still holds each one.
    static func ownedCopies(_ cards: [OwnedCard]) -> [OwnedCopy] {
        cards
            .filter { $0.productId > 0 && $0.isCommitted && !$0.isSealedSelf && !CardTagIndex.isSold($0) && $0.status != .lost }
            .map { OwnedCopy(productId: $0.productId, printing: $0.printing, quantity: max(1, $0.quantity)) }
    }

    /// The checklist order: collector number, then name, then printing.
    static func build(hits: [SearchHit], prices: [Int: [ProductPrice]], owned: [OwnedCopy]) -> MasterSet {
        var held: [Int: [String: Int]] = [:]
        for copy in owned {
            held[copy.productId, default: [:]][copy.printing, default: 0] += copy.quantity
        }

        var slots: [Slot] = []
        for hit in hits.sorted(by: checklistOrder) {
            let copies = held[hit.productId] ?? [:]
            let unset = copies[""] ?? 0
            let rows = (prices[hit.productId] ?? []).sorted { printingRank($0.subTypeName) < printingRank($1.subTypeName) }
            if rows.isEmpty {
                // No printing to tell apart, so any copy fills the slot.
                let count = copies.values.reduce(0, +)
                slots.append(Slot(hit: hit, printing: nil, marketCents: nil, ownedCount: count))
                continue
            }
            for (index, row) in rows.enumerated() {
                var count = copies[row.subTypeName] ?? 0
                // With one printing there is nothing to confuse.
                if rows.count == 1 { count += unset }
                let note = rows.count > 1 && index == 0 ? unset : 0
                slots.append(Slot(hit: hit, printing: row.subTypeName, marketCents: row.marketCents, ownedCount: count, unsetPrintingCount: note))
            }
        }
        return MasterSet(slots: slots)
    }

    /// Normal, then the holos, then everything else by name.
    static func printingRank(_ name: String) -> (Int, String) {
        switch name {
        case "Normal": return (0, name)
        case "Holofoil": return (1, name)
        case "Reverse Holofoil": return (2, name)
        default: return (3, name)
        }
    }

    /// A card with a collector number sorts before one without, and digits
    /// compare as numbers, so 9/128 comes before 10/128.
    static func checklistOrder(_ a: SearchHit, _ b: SearchHit) -> Bool {
        switch (a.numberNum, b.numberNum) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        let order = (a.number ?? "").localizedStandardCompare(b.number ?? "")
        if order != .orderedSame { return order == .orderedAscending }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

extension CatalogSearch {
    /// Every single in the set with its price rows. No limit, because a
    /// checklist with a card missing is wrong.
    func masterSetContents(groupId: Int) async throws -> (hits: [SearchHit], prices: [Int: [ProductPrice]]) {
        try await database.asyncRead { db in
            try Self.masterSetContents(db, groupId: groupId)
        }
    }

    static func masterSetContents(_ db: Database, groupId: Int) throws -> (hits: [SearchHit], prices: [Int: [ProductPrice]]) {
        let ids = try Int.fetchAll(db, sql: "SELECT productId FROM product WHERE groupId = ? AND isSealed = 0", arguments: [groupId])
        guard !ids.isEmpty else { return ([], [:]) }
        let hits = try fetchHits(db, ids: ids, filter: SearchFilter())
        let placeholders = ids.map(String.init).joined(separator: ",")
        var prices: [Int: [ProductPrice]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT productId, subTypeName, marketPriceCents, lowPriceCents, asOf FROM price WHERE productId IN (\(placeholders))") {
            let price = ProductPrice(subTypeName: row["subTypeName"], marketCents: row["marketPriceCents"], asOf: row["asOf"], lowCents: row["lowPriceCents"])
            prices[row["productId"], default: []].append(price)
        }
        return (hits, prices)
    }
}
