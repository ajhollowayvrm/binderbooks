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
    static func allocate(_ purchase: Purchase) {
        let billable = purchase.items.filter { !$0.isBulkOnly }
        for item in purchase.items where item.isBulkOnly {
            item.allocatedCostCents = 0
        }
        guard !billable.isEmpty else { return }

        let unitCount = billable.reduce(0) { $0 + max(1, $1.quantity) }
        let shares = splitEqually(purchase.landedCostCents, into: unitCount)

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
            let tracked = cards.filter { !$0.isBulk }
            for card in cards where card.isBulk {
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
