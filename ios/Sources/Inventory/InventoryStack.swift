import Foundation

/// Copies of one thing, shown as one line with a count.
///
/// Nine packs off one purchase are nine `OwnedCard` rows, because each pack is
/// ripped on its own and carries its own share of what the purchase cost. The
/// page must not read as nine identical cells, so cards that would draw the
/// same cell collapse into one of these and the count goes on the art.
///
/// This is a display grouping only. Nothing is written, the store keeps every
/// copy, and `InventoryModel.rows` still answers per card — the sort, the
/// filters, the query and Metrics all run on those rows before the grouping.
struct InventoryStack: Identifiable {
    /// Every copy, in the page's order.
    var rows: [InventoryRow]

    /// The copy the line draws. The first in the page's order, so the cell
    /// sits where that card sorted.
    var lead: InventoryRow { rows[0] }

    var id: UUID { lead.id }

    var cardIds: [UUID] { rows.map(\.card.id) }

    /// Cards, not lines: a bulk line of 40 counts 40, the same figure the row
    /// showed before stacking existed.
    var copies: Int { rows.reduce(0) { $0 + max(1, $1.card.quantity) } }

    /// True when the line stands for more than one card, which is when it can
    /// be opened as a stack. A bulk line of 40 is one card and is not stacked.
    var isStacked: Bool { rows.count > 1 }

    /// The whole stack at market, every copy counted. Nil when nothing in it
    /// is priced. A graded card counts at what its slab is worth, the same
    /// rule the row's own figure follows — though a slab never stacks.
    var totalValueCents: Int? {
        let priced = rows.compactMap { row -> Int? in
            guard let unit = row.gradedValueCents ?? row.marketCents else { return nil }
            return unit * max(1, row.card.quantity)
        }
        return priced.isEmpty ? nil : priced.reduce(0, +)
    }

    /// What every copy cost, added up. Shares split out of a purchase count,
    /// the same as on one row.
    var totalBasisCents: Int { rows.reduce(0) { $0 + $1.card.totalBasisCents } }

    /// The gain over the whole stack. Only the copies that have both a cost
    /// and a price count, so it is nil exactly when no copy shows a gain.
    var unrealizedCents: Int? {
        let gains = rows.compactMap(\.unrealizedCents)
        return gains.isEmpty ? nil : gains.reduce(0, +)
    }

    /// The labels every copy carries, in the lead copy's order. The line draws
    /// these the way it draws one card's.
    var sharedTags: [String] {
        lead.card.tags.filter { tag in rows.allSatisfy { CardTagIndex.has(tag, on: $0.card) } }
    }

    /// True when every copy is in the personal collection.
    var isAllPersonal: Bool { rows.allSatisfy(\.card.isPersonalCollection) }

    /// A label only some copies carry, and how many copies carry it.
    struct MixedLabel: Hashable {
        var label: String
        var copies: Int
    }

    /// The labels that differ between copies, "PC" included. One copy listed
    /// and one not is still one line, so the line says which part is listed.
    var mixedLabels: [MixedLabel] {
        var order: [String] = []
        var display: [String: String] = [:]
        var counts: [String: Int] = [:]
        for row in rows {
            let labels = row.card.tags + (row.card.isPersonalCollection ? ["PC"] : [])
            for label in Set(labels.map(TagKey.of)) {
                if display[label] == nil {
                    order.append(label)
                    display[label] = labels.first { TagKey.of($0) == label }
                }
                counts[label, default: 0] += max(1, row.card.quantity)
            }
        }
        return order.compactMap { key in
            guard let count = counts[key], count < copies, let label = display[key] else { return nil }
            return MixedLabel(label: label, copies: count)
        }
    }

    /// What the line's badges say: the shared labels, then "1 of 2 listed"
    /// for each label only some copies carry.
    var badges: [String] {
        sharedTags + mixedLabels.map { "\($0.copies) of \(copies) \($0.label)" }
    }

    /// Where a tap goes. One card opens that card. A stack opens the copies,
    /// because the lead card's detail would hide the other eight — and each
    /// one has its own cost, its own tags, and its own pack to rip.
    var route: AppRoute {
        isStacked ? .cardStack(lead.card.id) : .ownedCard(lead.card.id)
    }

    /// What makes two cards one line on the page: the same product, the same
    /// printing, condition and language, and the same kind of thing.
    ///
    /// The labels and the personal collection are not in here. They say what
    /// a copy is doing, not what it is, so a listed copy and an unlisted copy
    /// are one line with a count. AJ's call, 2026-09-22. The line shows a label
    /// only some copies carry as "1 of 2 listed", so the stack hides nothing.
    ///
    /// A slab is one of a kind — its cert, its grade and its value are its own
    /// — so it carries its id and stacks with nothing.
    struct Key: Hashable {
        var unique: UUID?
        var productId: Int
        var manualName: String
        var manualNumber: String
        var printing: String
        var condition: String
        var language: String
        var isSealedSelf: Bool
        var isBulk: Bool
        var manualMarketCents: Int?
    }

    static func key(for card: OwnedCard) -> Key {
        Key(
            unique: card.isSlabbed ? card.id : nil,
            productId: card.productId,
            manualName: card.manualName,
            manualNumber: card.manualNumber,
            printing: card.printing,
            condition: card.condition,
            language: card.language,
            isSealedSelf: card.isSealedSelf,
            isBulk: card.isBulk,
            manualMarketCents: card.manualMarketCents
        )
    }

    /// Groups rows that would draw the same line. The order is the order the
    /// rows arrived in: a stack sits where its first copy sorted, so a sort or
    /// a filter reads the same with stacking as without it.
    static func stacks(_ rows: [InventoryRow]) -> [InventoryStack] {
        var order: [Key] = []
        var groups: [Key: [InventoryRow]] = [:]
        for row in rows {
            let rowKey = key(for: row.card)
            if groups[rowKey] == nil { order.append(rowKey) }
            groups[rowKey, default: []].append(row)
        }
        return order.compactMap { (stackKey: Key) -> InventoryStack? in
            guard let members = groups[stackKey], !members.isEmpty else { return nil }
            return InventoryStack(rows: members)
        }
    }

    /// The copies of one card, out of the rows the page already has. Nil when
    /// the card is gone — sold, deleted, or filtered off the page.
    static func stack(of cardID: UUID, in rows: [InventoryRow]) -> InventoryStack? {
        guard let lead = rows.first(where: { $0.card.id == cardID }) else { return nil }
        let wanted = key(for: lead.card)
        let members = rows.filter { key(for: $0.card) == wanted }
        return members.isEmpty ? nil : InventoryStack(rows: members)
    }
}
