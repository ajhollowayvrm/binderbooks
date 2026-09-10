import Foundation

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
    static func allocate(_ purchase: Purchase) {
        for item in purchase.items where item.isBulkOnly {
            item.allocatedCostCents = 0
        }
        let manual = purchase.items.filter { !$0.isBulkOnly && $0.isManualOnly }
        for item in manual {
            item.allocatedCostCents = item.cards.reduce(0) { $0 + $1.acquisitionBasisCents }
        }
        let billable = purchase.items.filter { !$0.isBulkOnly && !$0.isManualOnly }
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

    /// Writes each card's basis from its line. A line with several cards splits
    /// its share equally among them.
    static func writeCardBases(_ purchase: Purchase) {
        for item in purchase.items {
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
