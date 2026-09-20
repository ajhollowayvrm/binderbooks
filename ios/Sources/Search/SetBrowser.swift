import Foundation

/// Reading the catalog by set, rather than by card.
///
/// Every other way into a set starts from a card he already has, or from a
/// query he already typed. `MasterSetView` could read a whole set from the
/// start, but the only way to reach it was to pick a set in the filter picker
/// and then find a chip, so a set he holds nothing from was effectively
/// unreachable — which is exactly the set he wants to read before he buys.
///
/// The counting lives here, out of the view, because "how many of this set do I
/// hold" is the one part worth pinning with a test.
enum SetBrowser {
    /// How many distinct cards of each set he holds, keyed by group id.
    ///
    /// Distinct cards, not copies: nine of one card is one card of the set
    /// filled. A set he holds nothing from is absent rather than zero, so a row
    /// can tell "none" from "not counted yet" while the catalog hits load.
    ///
    /// `MasterSet.ownedCopies` decides what counts as held, so this agrees with
    /// the checklist the row opens. `hits` is `InventoryModel`'s product cache,
    /// which already carries each product's set.
    static func heldCounts(cards: [OwnedCard], hits: [Int: SearchHit]) -> [Int: Int] {
        var products: [Int: Set<Int>] = [:]
        for copy in MasterSet.ownedCopies(cards) {
            guard let groupId = hits[copy.productId]?.groupId else { continue }
            products[groupId, default: []].insert(copy.productId)
        }
        return products.mapValues(\.count)
    }

    /// The sets a typed needle keeps. The name or the code, the way the set
    /// picker has always matched, so "MEP" finds "ME: Mega Evolution Promo".
    static func visible(_ sets: [SetSummary], query: String) -> [SetSummary] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return sets }
        let clean = NameCleaner.clean(needle)
        guard !clean.isEmpty else { return sets }
        return sets.filter {
            NameCleaner.clean($0.name).contains(clean)
                || ($0.abbreviation.map { NameCleaner.clean($0).contains(clean) } ?? false)
        }
    }

    /// Pokemon first, then every other category in the order the catalog lists
    /// them. He owns one kind of card; the rest are there because the catalog
    /// carries them, and they should not be in the way.
    static func grouped(_ sets: [SetSummary]) -> [(category: String, sets: [SetSummary])] {
        var order: [String] = []
        var buckets: [String: [SetSummary]] = [:]
        for set in sets {
            if buckets[set.categoryName] == nil { order.append(set.categoryName) }
            buckets[set.categoryName, default: []].append(set)
        }
        // Partitioned, not sorted. `sort` is not stable in Swift, so a
        // comparator that only knows "Pokemon first" would reorder the rest.
        let ordered = order.filter(isPokemon) + order.filter { !isPokemon($0) }
        return ordered.map { ($0, buckets[$0] ?? []) }
    }

    private static func isPokemon(_ category: String) -> Bool {
        NameCleaner.clean(category).contains("pokemon")
    }
}
