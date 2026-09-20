import Foundation

/// Works out which sets a rip is expected to produce, from the sealed products
/// being opened.
///
/// The brief forbids a "choose your sets" step, and is right to: it would be a
/// setup screen in front of the one action he does three hundred times a night,
/// and the scanner is meant to open and read. But the information the step
/// would ask for is already sitting there — he has just told the app exactly
/// which booster box he is cutting open, and a booster box has a set.
///
/// So the scope is derived rather than requested. He is never asked, and the
/// chip in the scan screen lets him correct it when the catalog files a product
/// somewhere surprising.
enum RipSetHint {
    /// The sets these products belong to, most-opened first.
    ///
    /// Order matters a little: a rip of two different boxes should lead with
    /// the one he has more of, because that is the one most of the cards will
    /// come from.
    static func groupIds(for hits: [SearchHit]) -> [Int] {
        var counts: [Int: Int] = [:]
        var firstSeen: [Int: Int] = [:]
        for (index, hit) in hits.enumerated() {
            counts[hit.groupId, default: 0] += 1
            if firstSeen[hit.groupId] == nil { firstSeen[hit.groupId] = index }
        }
        return counts.keys.sorted { left, right in
            let a = counts[left] ?? 0
            let b = counts[right] ?? 0
            if a != b { return a > b }
            return (firstSeen[left] ?? 0) < (firstSeen[right] ?? 0)
        }
    }

    /// Look the products up and set the scope on the session.
    ///
    /// Quiet on failure on purpose. A scope is a convenience, and a rip that
    /// cannot resolve one must still open the scanner: the matcher's own
    /// signals are what identify a card, and they worked before this existed.
    @MainActor
    static func apply(to session: ScanSession, productIds: [Int], catalog: CatalogController) async {
        let ids = Array(Set(productIds.filter { $0 > 0 }))
        guard !ids.isEmpty, let database = catalog.database else { return }
        guard let hits = try? await CatalogSearch(database: database).hits(ids: ids) else { return }
        let groups = groupIds(for: hits)
        guard !groups.isEmpty else { return }
        session.preferredGroupIds = groups
    }
}
