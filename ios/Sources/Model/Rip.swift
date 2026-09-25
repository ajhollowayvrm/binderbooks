import Foundation
import SwiftData

/// Ripping sealed packs: the packs leave inventory, and the pulls come in
/// through an ordinary scan.
///
/// What the packs cost moves to the pulls when the scan commits, split by
/// market price. See `CostBasis.moveRipCost`. The purchase that bought the
/// packs stays on the books as it is, and the pulls have no link to it. So a
/// rip only has to remember which packs it opens until the scan commits.
///
/// The pack ids live in `UserDefaults`, one key for each scan session. They do
/// not live on the session's own cards, because a discarded session deletes
/// its cards. If a key is lost, the packs stay sealed. That failure is safe.
///
/// The packs leave inventory only at `finish`, when the scan commits. A scan
/// he discards changes nothing.
enum Rip {
    /// The packs among `cards` that can rip: sealed self-cards not sold. A sold
    /// pack keeps its self-card, because its order points at it.
    static func rippable(_ cards: [OwnedCard]) -> [OwnedCard] {
        cards.filter { $0.isSealedSelf && !CardTagIndex.isSold($0) }
    }

    static func key(for session: ScanSession) -> String {
        "ripPacks.\(session.id.uuidString)"
    }

    /// Makes the scan session for a rip of these packs and records the packs.
    /// Nothing leaves inventory yet. With a catalog, the session also takes
    /// the sets of the packs as its scope. See `RipSetHint`.
    /// Returns nil when none of the cards can rip.
    @MainActor
    @discardableResult
    static func start(
        _ packs: [OwnedCard],
        context: ModelContext,
        catalog: CatalogController? = nil,
        defaults: UserDefaults = .standard
    ) -> ScanSession? {
        let opening = rippable(packs)
        guard !opening.isEmpty else { return nil }
        let session = ScanSession()
        session.preferredGroupIds = []
        context.insert(session)
        try? context.save()
        defaults.set(opening.map(\.id.uuidString), forKey: key(for: session))
        if let catalog {
            // The sets these packs belong to, so the matcher knows what to
            // expect. He is not asked: he has just said which boxes he is
            // opening, and a box has a set.
            let productIds = opening.map(\.productId)
            Task { @MainActor in
                await RipSetHint.apply(to: session, productIds: productIds, catalog: catalog)
                try? context.save()
            }
        }
        return session
    }

    /// The packs this session rips. Empty when the session is not a rip.
    static func packIds(for session: ScanSession, defaults: UserDefaults = .standard) -> [UUID] {
        (defaults.stringArray(forKey: key(for: session)) ?? []).compactMap(UUID.init(uuidString:))
    }

    static func isRip(_ session: ScanSession, defaults: UserDefaults = .standard) -> Bool {
        !packIds(for: session, defaults: defaults).isEmpty
    }

    /// The rip itself, when the scan commits. Each recorded pack that is still
    /// sealed and not sold leaves inventory, and its cost moves to the pulls.
    ///
    /// `marketCents` weighs the pulls. With no prices, the cost splits equally.
    static func finish(
        _ session: ScanSession,
        context: ModelContext,
        marketCents: (OwnedCard) -> Int? = { _ in nil },
        defaults: UserDefaults = .standard
    ) {
        let ids = packIds(for: session, defaults: defaults)
        if !ids.isEmpty {
            let packs = (try? context.fetch(FetchDescriptor<OwnedCard>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
            let opening = rippable(packs)
            CostBasis.moveRipCost(from: opening, to: session.cards, marketCents: marketCents)
            for pack in opening {
                context.delete(pack)
            }
            try? context.save()
        }
        forget(session, defaults: defaults)
    }

    /// A scan he discarded. The key goes, and the packs stay sealed.
    static func forget(_ session: ScanSession, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: session))
    }

    /// A rip with nothing to scan. The packs leave inventory at once, and
    /// their cost goes with them: no card is left to carry it. The purchase
    /// that bought them stays on the books.
    static func ripWithNothing(_ packs: [OwnedCard], context: ModelContext) {
        let opening = rippable(packs)
        CostBasis.moveRipCost(from: opening, to: [], marketCents: { _ in nil })
        for pack in opening {
            context.delete(pack)
        }
        try? context.save()
    }
}
