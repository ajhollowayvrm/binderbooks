import Foundation
import SwiftUI

/// The sets he is master setting, and the copies a TCGplayer file holds back
/// for them.
///
/// He sells the bulk of a set he is still building. One copy of every card in
/// that set must stay out of the listing file, or he sells his own master set
/// away. The flag is per set and it persists, so every later export holds a
/// copy back without him thinking about it.
///
/// A slot is a product and a printing, as `MasterSet` counts them, so a
/// reverse holo keeps its own copy.
enum MasterSetHold {
    /// The group ids, as one defaults string. `@AppStorage` holds a string and
    /// not a set, so the string is the stored form everywhere.
    static let defaultsKey = "masterSettingGroupIds"

    static func ids(_ text: String) -> Set<Int> {
        Set(text.split(separator: ",").compactMap { Int($0) })
    }

    /// Sorted and comma separated, so the same sets always write the same
    /// string.
    static func text(_ ids: Set<Int>) -> String {
        ids.sorted().map(String.init).joined(separator: ",")
    }

    static func text(_ stored: String, setting groupId: Int, to on: Bool) -> String {
        var all = ids(stored)
        if on { all.insert(groupId) } else { all.remove(groupId) }
        return text(all)
    }

    /// One slot of a master set.
    struct SlotKey: Hashable, Sendable {
        var productId: Int
        var printing: String
    }

    /// The copy of each slot to keep, for the sets in `groups`.
    ///
    /// This reads every row, not only the listable ones. A slab, a personal
    /// collection card, and a card at the grader fill their slot and never
    /// reach the file, so a slot they fill holds nothing back.
    /// `MasterSet.ownedCopies` decides what counts as held, so this agrees
    /// with the checklist.
    ///
    /// Of the copies he can list, the best condition stays. AJ's call,
    /// 2026-09-21: the set keeps the Near Mint copy, and the played copies
    /// sell.
    static func keep(from rows: [InventoryRow], prices: [Int: [ProductPrice]], groups: Set<Int>) -> Set<UUID> {
        guard !groups.isEmpty else { return [] }
        var filled: Set<SlotKey> = []
        var best: [SlotKey: InventoryRow] = [:]
        for row in rows {
            guard let hit = row.hit, groups.contains(hit.groupId), !hit.isSealed, holds(row.card) else { continue }
            guard let printing = TCGplayerListingExport.printing(for: row.card, prices: prices[hit.productId] ?? []) else { continue }
            let key = SlotKey(productId: hit.productId, printing: printing)
            if TCGplayerListingExport.skipReason(for: row.card, hit: hit) != nil {
                filled.insert(key)
                continue
            }
            if let kept = best[key], rank(kept) <= rank(row) { continue }
            best[key] = row
        }
        return Set(best.filter { !filled.contains($0.key) }.map { $0.value.card.id })
    }

    /// The cards that fill a slot, as `MasterSet.ownedCopies` counts them.
    private static func holds(_ card: OwnedCard) -> Bool {
        card.productId > 0 && card.isCommitted && !card.isSealedSelf && !CardTagIndex.isSold(card) && card.status != .lost
    }

    /// Best condition first. The date and the id break a tie, so the same
    /// inventory always keeps the same copy.
    private static func rank(_ row: InventoryRow) -> (Int, Date, String) {
        let condition = CardCondition.allCases.firstIndex { $0.rawValue == row.card.condition }
        return (condition ?? CardCondition.allCases.count, row.card.acquiredAt, row.card.id.uuidString)
    }
}

/// The cards the inventory page marks as kept for a master set. A screen that
/// does not compute the hold leaves it empty and marks nothing.
///
/// The hold reads every copy he holds, so only a screen that has them all can
/// work it out. `InventoryView` does, and it passes the answer down to the
/// rows and the cells.
private struct MasterSetHeldKey: EnvironmentKey {
    static let defaultValue: Set<UUID> = []
}

extension EnvironmentValues {
    var masterSetHeld: Set<UUID> {
        get { self[MasterSetHeldKey.self] }
        set { self[MasterSetHeldKey.self] = newValue }
    }
}

/// The star and the words, wherever a card says it is kept for a master set.
struct MasterSetBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
            Text("master set")
        }
        .foregroundStyle(.green)
    }
}
