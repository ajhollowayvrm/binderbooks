import Foundation
import SwiftData

/// Deletes the raw singles he holds, so he can scan his cards again.
///
/// AJ asked for this on 2026-09-26. He wiped his TCGplayer inventory the same
/// day, and he will rescan and list fewer cards.
///
/// A raw single is a committed card that he holds and that is not a slab, a
/// sealed item, a personal-collection card, or a card at a grader. The wipe
/// keeps a card that a sale line or a grading entry points at, because the
/// ledger reads that card. A purchase keeps its cost, the same as any card
/// delete.
@MainActor
enum SinglesWipe {
    static func isTarget(_ card: OwnedCard) -> Bool {
        card.isCommitted
            && !CardTagIndex.isSold(card)
            && !card.isSealedSelf
            && !card.isSlabbed
            && !card.isPersonalCollection
            && card.status != .atGrader
            && card.status != .lost
            && !CardTagIndex.has(ReservedTag.lost, on: card)
            && !ReservedTag.allAtGrader.contains { CardTagIndex.has($0, on: card) }
    }

    /// The cards the wipe deletes.
    static func targets(_ context: ModelContext) throws -> [OwnedCard] {
        let onLedger = Set(try context.fetch(FetchDescriptor<SaleLine>()).compactMap { $0.card?.id })
            .union(try context.fetch(FetchDescriptor<GradingEntry>()).compactMap { $0.card?.id })
        return try context.fetch(FetchDescriptor<OwnedCard>())
            .filter { isTarget($0) && !onLedger.contains($0.id) }
    }

    /// Deletes the targets and their photos. Returns the number of cards it deleted.
    @discardableResult
    static func run(_ context: ModelContext) throws -> Int {
        let cards = try targets(context)
        let ids = cards.map(\.id)
        for card in cards { context.delete(card) }
        try context.save()
        CardPhotoStore.remove(ids)
        return ids.count
    }
}
