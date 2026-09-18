import Foundation
import SwiftData

/// Ripping several sealed packs as one rip.
///
/// He opens a whole order in one sitting, then records what came out. The
/// pulls are measured against every pack he opened, not one pack each. So the
/// lines he rips together share a `ripGroupId`, and their pulls share their
/// combined cost. This is not a record of the rip: it records no date, only
/// which lines' cost the pulls share. See "There is no RipEvent" in docs/02.
///
/// Each line keeps its own purchase and its share of that purchase. The pulls
/// hang on one line, the home line, so each pull has one source. A pack's cost
/// never moves to another purchase.
///
/// The packs leave inventory only at `finish`, when the scan commits. A scan
/// he discards changes nothing.
enum RipPool {
    /// Makes the lines for a rip of these sealed self-cards and returns the
    /// home line: the line with the most packs, the first one on a tie.
    ///
    /// Packs on one line become one line of that many units. Packs from
    /// several lines, or several purchases, get one new `ripGroupId`. Nothing
    /// is ripped yet.
    static func prepare(_ selfCards: [OwnedCard], context: ModelContext) -> PurchaseItem? {
        let packs = rippable(selfCards)
        guard !packs.isEmpty else { return nil }

        var order: [UUID] = []
        var byLine: [UUID: (line: PurchaseItem, cards: [OwnedCard])] = [:]
        var lines: [PurchaseItem] = []
        for card in packs {
            guard let line = card.sourceItem else {
                // A pack added to inventory with no purchase behind it.
                lines.append(Allocation.ripTarget(for: card, context: context))
                continue
            }
            if byLine[line.id] == nil {
                order.append(line.id)
                byLine[line.id] = (line, [])
            }
            byLine[line.id]?.cards.append(card)
        }
        for id in order {
            guard let entry = byLine[id] else { continue }
            lines.append(Allocation.carve(entry.cards, from: entry.line, context: context))
        }

        let group: UUID? = lines.count > 1 ? UUID() : nil
        for line in lines { line.ripGroupId = group }
        try? context.save()

        var home = lines[0]
        for line in lines.dropFirst() where line.quantity > home.quantity { home = line }
        return home
    }

    /// The packs among `cards` that can rip: sealed self-cards not sold. A sold
    /// pack keeps its self-card, because its order points at it for its cost,
    /// and a rip deletes the self-cards it opens.
    static func rippable(_ cards: [OwnedCard]) -> [OwnedCard] {
        cards.filter { $0.isSealedSelf && !CardTagIndex.isSold($0) }
    }

    /// The rip itself. Every line in the group loses its sealed self-cards and
    /// is marked ripped, the pulls join the home line, and the pulls take their
    /// share of what the group cost. Run again with more pulls, it adds them.
    static func finish(_ home: PurchaseItem, pulls: [OwnedCard], acquiredAt: Date, context: ModelContext) {
        let group = lines(of: home)
        for card in pulls where card.sourceItem == nil {
            card.sourceItem = home
            card.acquiredAt = acquiredAt
        }
        for line in group {
            for card in line.cards where card.isSealedSelf {
                context.delete(card)
            }
            line.isRipped = true
        }
        // Flushed now, or the split below still counts the packs just deleted
        // and gives away a share of their cost to nothing.
        try? context.save()
        writeBases(lines(of: home))
        try? context.save()
    }

    /// A scan he discarded. Lines that were not ripped leave the group, and a
    /// line `prepare` carved joins its packs' line again, so each abandoned rip
    /// does not leave the purchase in one more piece.
    static func release(_ home: PurchaseItem, context: ModelContext) {
        guard !home.isRipped else { return }
        let group = lines(of: home).filter { !$0.isRipped }
        for line in group { line.ripGroupId = nil }
        for line in group { rejoin(line, context: context) }
        try? context.save()
    }

    /// Puts an unripped sealed line back into another unripped line of the
    /// same product on the same purchase. Equal shares per unit, so the join
    /// changes no cost.
    private static func rejoin(_ line: PurchaseItem, context: ModelContext) {
        guard line.isSealed, !line.isDeleted, let purchase = line.purchase else { return }
        guard let into = purchase.items.first(where: {
            $0.id != line.id && !$0.isDeleted && $0.isSealed && !$0.isRipped && $0.ripGroupId == nil
                && $0.productId == line.productId && $0.parentItem?.id == line.parentItem?.id
        }) else { return }
        into.quantity += line.quantity
        into.allocatedCostCents += line.allocatedCostCents
        for card in Array(line.cards) { card.sourceItem = into }
        // Saved first: deleting a line deletes the cards still on it.
        try? context.save()
        if line.cards.isEmpty { context.delete(line) }
    }

    /// Cards already in inventory that came out of this rip. A card alone on
    /// a line of its own was recorded as part of a buy, so that line goes and
    /// its purchase splits again without it. Returns the cards that moved.
    @MainActor
    @discardableResult
    static func addPulls(_ cards: [OwnedCard], to home: PurchaseItem, context: ModelContext) throws -> Int {
        let groupIds = Set(lines(of: home).map(\.id))
        var left: [Purchase] = []
        var emptied: [PurchaseItem] = []
        var moved = 0
        for card in cards where !card.isSealedSelf {
            if let line = card.sourceItem, groupIds.contains(line.id) { continue }
            let old = card.sourceItem
            if let purchase = old?.purchase, !left.contains(where: { $0.id == purchase.id }) {
                left.append(purchase)
            }
            if let old, !old.isRipped, !old.isSealed, !emptied.contains(where: { $0.id == old.id }) {
                emptied.append(old)
            }
            card.sourceItem = home
            if !card.basisIsManual, !card.isBulk {
                if card.acquisitionBasisCents == 0 || card.basisIsAllocated {
                    card.basisIsAllocated = true
                } else {
                    // A cost the old ledger carried stays his, the way
                    // `PurchaseLink` keeps it.
                    card.basisIsManual = true
                }
            }
            if let date = home.purchase?.date { card.acquiredAt = date }
            moved += 1
        }
        guard moved > 0 else { return 0 }
        try context.save()

        // Deleting a line deletes its cards, so only a line with none left goes.
        for line in emptied where line.cards.isEmpty {
            context.delete(line)
        }
        try context.save()

        for purchase in left {
            _ = PurchaseEditor.resplitIfSafe(purchase)
        }
        writeBases(lines(of: home))
        try context.save()
        return moved
    }

    /// Every line ripped with `item`, or `item` alone.
    static func lines(of item: PurchaseItem) -> [PurchaseItem] {
        guard let group = item.ripGroupId, let context = item.modelContext else { return [item] }
        let id: UUID? = group
        var found = (try? context.fetch(FetchDescriptor<PurchaseItem>(predicate: #Predicate { $0.ripGroupId == id }))) ?? []
        if !found.contains(where: { $0.id == item.id }) { found.append(item) }
        return found.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// The line the pulls hang on: the one that holds pulls, or else the one
    /// with the most packs.
    static func home(of group: [PurchaseItem]) -> PurchaseItem? {
        if let line = group.first(where: { $0.cards.contains { !$0.isSealedSelf } }) { return line }
        return group.max { $0.quantity < $1.quantity }
    }

    /// Splits the group's cost over its pulls. A pull he priced himself keeps
    /// its price, and that price comes out of the cost first. Bulk takes none.
    static func writeBases(_ group: [PurchaseItem]) {
        let cost = group.reduce(0) { $0 + $1.allocatedCostCents }
        let pulls = group.flatMap(\.cards)
            .filter { !$0.isSealedSelf && !$0.isDeleted }
            .sorted { $0.scannedAt == $1.scannedAt ? $0.id.uuidString < $1.id.uuidString : $0.scannedAt < $1.scannedAt }
        for card in pulls where card.isBulk && !card.basisIsManual {
            card.acquisitionBasisCents = 0
            card.basisIsAllocated = true
        }
        let typed = pulls.filter { !$0.isBulk && $0.basisIsManual }.reduce(0) { $0 + $1.acquisitionBasisCents }
        let tracked = pulls.filter { !$0.isBulk && !$0.basisIsManual }
        guard !tracked.isEmpty else { return }
        let shares = Allocation.splitEqually(max(0, cost - typed), into: tracked.count)
        for (card, share) in zip(tracked, shares) {
            card.acquisitionBasisCents = share
            card.basisIsAllocated = true
        }
    }

    /// How a rip did: what the packs cost against what came out of them. The
    /// rip is the truer read, not the per-card figure. See docs/04.
    struct Result: Equatable {
        var packs = 0
        var costCents = 0
        var pulls = 0
        var valueCents = 0
        /// Pulls with no market value, which the value leaves out.
        var unpriced = 0

        var netCents: Int { valueCents - costCents }
    }

    static func result(of group: [PurchaseItem], market: (OwnedCard) -> Int?) -> Result {
        var result = Result()
        for line in group {
            result.packs += max(1, line.quantity)
            result.costCents += line.allocatedCostCents
            for card in line.cards where !card.isSealedSelf {
                result.pulls += 1
                if let value = market(card) {
                    result.valueCents += value * max(1, card.quantity)
                } else {
                    result.unpriced += 1
                }
            }
        }
        return result
    }
}
