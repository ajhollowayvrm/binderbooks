import Foundation
import SwiftData

/// Cost allocation. Pure integer arithmetic; every split sums back exactly.
enum Allocation {
    /// Splits `totalCents` into `count` shares that sum to exactly `totalCents`.
    /// `splitEqually(100000, into: 3)` is `[33334, 33333, 33333]`.
    static func splitEqually(_ totalCents: Int, into count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let base = totalCents / count
        let remainder = totalCents % count
        return (0..<count).map { $0 < remainder ? base + 1 : base }
    }

    /// Splits `totalCents` in proportion to `weights`, and the shares sum to
    /// exactly `totalCents`. The cents that rounding leaves go to the largest
    /// remainders, then to the earliest index. Weights that sum to zero split
    /// equally. `splitByWeight(100, weights: [1, 1, 1])` is `[34, 33, 33]`.
    /// `totalCents` must not be negative.
    static func splitByWeight(_ totalCents: Int, weights: [Int]) -> [Int] {
        let sum = weights.reduce(0) { $0 + max(0, $1) }
        guard sum > 0 else { return splitEqually(totalCents, into: weights.count) }
        var shares = weights.map { totalCents * max(0, $0) / sum }
        let left = totalCents - shares.reduce(0, +)
        let order = weights.indices.sorted { a, b in
            let ra = totalCents * max(0, weights[a]) % sum
            let rb = totalCents * max(0, weights[b]) % sum
            return ra == rb ? a < b : ra > rb
        }
        for index in order.prefix(max(0, left)) { shares[index] += 1 }
        return shares
    }

    /// Equal split across a purchase's billable units. A line of 4 copies is 4
    /// shares. Bulk lines are excluded from the denominator.
    ///
    /// Why bulk is excluded: a $4.97 pack with 3 hits and 7 commons gives each
    /// hit about $1.66 instead of spreading $0.50 across ten cards, seven of
    /// which go to the LGS pile for a few dollars.
    /// A card he priced at review keeps that price. Its money comes out of the
    /// purchase total first, and what is left splits over the cards he did not
    /// price. Typing more than the total leaves the split at zero rather than
    /// rewriting anything he entered.
    ///
    /// A ripped line is always billable. Its cost is what the packs cost, and
    /// the pulls do not change that: packs of bulk still cost money.
    static func allocate(_ purchase: Purchase) {
        for item in purchase.items where item.isBulkOnly && !item.isRipped {
            item.allocatedCostCents = 0
        }
        let manual = purchase.items.filter { !$0.isRipped && !$0.isBulkOnly && $0.isManualOnly }
        for item in manual {
            item.allocatedCostCents = item.cards.reduce(0) { $0 + $1.acquisitionBasisCents }
        }
        let billable = purchase.items.filter { $0.isRipped || (!$0.isBulkOnly && !$0.isManualOnly) }
        guard !billable.isEmpty else { return }

        let manualTotal = manual.reduce(0) { $0 + $1.allocatedCostCents }
        let remaining = max(0, purchase.landedCostCents - manualTotal)
        let unitCount = billable.reduce(0) { $0 + max(1, $1.quantity) }
        let shares = splitEqually(remaining, into: unitCount)

        var cursor = 0
        for item in billable {
            let quantity = max(1, item.quantity)
            item.allocatedCostCents = shares[cursor ..< cursor + quantity].reduce(0, +)
            cursor += quantity
        }
    }

    /// Equal split of a submission's total cost across its entries. Correct
    /// here, because the grader charged per card.
    static func allocate(_ submission: GradingSubmission) {
        let entries = submission.entries.sorted { $0.id.uuidString < $1.id.uuidString }
        let shares = splitEqually(submission.totalCostCents, into: entries.count)
        for (entry, share) in zip(entries, shares) {
            entry.allocatedFeeCents = share
        }
    }

    /// Puts each entry's share of the fee onto its card.
    ///
    /// This runs when the cards go out, not only when they come back. The P&L
    /// counts a submission in purchases from the moment it exists, so a fee
    /// sitting on the submission and not on the cards reads as a straight loss
    /// for as long as they are away. Both sides, or neither.
    static func capitalise(_ submission: GradingSubmission) {
        for entry in submission.entries {
            entry.card?.gradingBasisCents = entry.allocatedFeeCents
        }
    }

    /// The one line to rip for this sealed self-card: itself, if it already
    /// covers a single unit, or a new line carved out of it otherwise.
    /// Idempotent — a card already on its own line comes back unchanged.
    static func isolate(_ card: OwnedCard, context: ModelContext) -> PurchaseItem? {
        guard let item = card.sourceItem else { return nil }
        guard item.quantity > 1 else { return item }
        return carve([card], from: item, context: context)
    }

    /// A line for exactly these sealed self-cards, carved out of `item`.
    ///
    /// A box bought three at a time shares one `PurchaseItem` at `quantity: 3`.
    /// Ripping some of them must not touch the cost of the others, so they are
    /// split off first: a new line at `quantity: k` takes k equal shares of the
    /// shared line's `allocatedCostCents`, and the chosen cards move onto it.
    /// When the cards are the whole line, the line itself comes back.
    static func carve(_ cards: [OwnedCard], from item: PurchaseItem, context: ModelContext) -> PurchaseItem {
        let chosen = Set(cards.map(\.id))
        let others = item.cards.filter { !chosen.contains($0.id) }
        let quantity = max(1, item.quantity)
        let count = min(cards.count, quantity)
        if others.isEmpty, count == quantity { return item }

        let shares = splitEqually(item.allocatedCostCents, into: quantity)
        let unit = PurchaseItem(productId: item.productId, quantity: count, isSealed: item.isSealed)
        unit.purchase = item.purchase
        unit.parentItem = item.parentItem
        unit.allocatedCostCents = shares.suffix(count).reduce(0, +)
        context.insert(unit)

        item.quantity = quantity - count
        item.allocatedCostCents -= unit.allocatedCostCents
        for card in cards { card.sourceItem = unit }
        if item.quantity == 0, others.isEmpty {
            context.delete(item)
        }
        return unit
    }

    /// The line to rip for a sealed self-card, creating one when the card was
    /// added to inventory standing alone, with no purchase behind it.
    static func ripTarget(for card: OwnedCard, context: ModelContext) -> PurchaseItem {
        if let item = isolate(card, context: context) { return item }
        let item = PurchaseItem(productId: card.productId, quantity: 1, isSealed: true)
        item.allocatedCostCents = card.acquisitionBasisCents
        context.insert(item)
        card.sourceItem = item
        return item
    }

    /// Writes each card's basis from its line. A line with several cards splits
    /// its share equally among them.
    ///
    /// A ripped line is different: its pulls share the cost of every line ripped
    /// with it, which can sit on other purchases. See `RipPool.writeBases`.
    static func writeCardBases(_ purchase: Purchase) {
        var ripped = Set<UUID>()
        for item in purchase.items {
            if item.isRipped {
                guard !ripped.contains(item.id) else { continue }
                let group = RipPool.lines(of: item)
                ripped.formUnion(group.map(\.id))
                RipPool.writeBases(group)
                continue
            }
            let cards = item.cards.sorted { $0.scannedAt < $1.scannedAt }
            // Never overwrite a price he typed.
            let tracked = cards.filter { !$0.isBulk && !$0.basisIsManual }
            for card in cards where card.isBulk && !card.basisIsManual {
                card.acquisitionBasisCents = 0
                card.basisIsAllocated = true
            }
            guard !tracked.isEmpty else { continue }
            let shares = splitEqually(item.allocatedCostCents, into: tracked.count)
            for (card, share) in zip(tracked, shares) {
                card.acquisitionBasisCents = share
                card.basisIsAllocated = true
            }
        }
    }
}
