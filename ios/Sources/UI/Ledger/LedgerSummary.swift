import Foundation

/// What the books say, over the whole period and over the whole business.
///
/// The ledger answers "what happened". This answers "how am I actually doing",
/// which is the one-sentence goal in docs/00-brief.md and which a list of
/// transactions cannot answer.
///
/// It totals and it does not slice. No vendor, no set, no product, no channel —
/// decision 23 in docs/00-brief.md, amended 2026-09-11 to allow the totals and
/// the P&L and nothing else. Every number here is arithmetic over the store, so
/// there is no stored `PeriodSummary` that could disagree with it.
struct LedgerSummary: Equatable {
    // Cash, the three rows that used to sit on top of the transaction list.
    var moneyInCents = 0
    var moneyOutCents = 0

    // Profit, realized out of orders.
    var realizedGainCents = 0
    /// Orders whose gain is known, and orders in total. A gain covering three
    /// quarters of the book is a number that gets trusted wrongly, so both
    /// halves travel together and the view prints both.
    var ordersWithKnownBasis = 0
    var orderCount = 0

    // The periodic P&L, from docs/02-data-model.md.
    var beginningInventoryCents = 0
    var purchasesCents = 0
    var endingInventoryCents = 0
    var revenueCents = 0
    var expensesCents = 0

    // Position.
    var heldCardCount = 0
    var heldAtCostCents = 0
    var heldAtMarketCents = 0
    /// Market and cost over the cards carrying both, so the difference compares
    /// like with like. Mirrors `InventorySummary`.
    var pricedMarketCents = 0
    var pricedBasisCents = 0
    var allocatedCount = 0
    var atGraderCount = 0

    var differenceCents: Int { moneyInCents - moneyOutCents }
    var unrealizedCents: Int { pricedMarketCents - pricedBasisCents }

    /// `COGS = beginningInventory + purchases − endingInventory`
    var costOfGoodsSoldCents: Int {
        beginningInventoryCents + purchasesCents - endingInventoryCents
    }

    /// `P&L = revenue − COGS − expenses`
    var profitCents: Int {
        revenueCents - costOfGoodsSoldCents - expensesCents
    }

    var ordersWithUnknownBasis: Int { orderCount - ordersWithKnownBasis }
}

extension LedgerSummary {
    /// Whether a card is still inventory he holds.
    ///
    /// A sold card keeps its row and its basis, so anything totalling cost or
    /// value must drop it by hand. Miss this and ending inventory, the
    /// position, and the P&L are all inflated by everything he has ever sold.
    ///
    /// Sold is `CardTagIndex.isSold`, the same predicate the inventory uses, so
    /// a card cannot be off the inventory page and inside the ending inventory
    /// at the same time. A written-off card is gone too, and the ledger is the
    /// only place that cares about the difference.
    static func isHeld(_ card: OwnedCard) -> Bool {
        if CardTagIndex.isSold(card) { return false }
        return !CardTagIndex.has(ReservedTag.lost, on: card) && card.status != .lost
    }

    /// A card out at a grader, by either signal, for the same reason.
    static func isAtGrader(_ card: OwnedCard) -> Bool {
        if card.status == .atGrader { return true }
        return [ReservedTag.atGrader, ReservedTag.atPSA, ReservedTag.atCGC]
            .contains { CardTagIndex.has($0, on: card) }
    }

    /// Cash and profit, from the money rows alone.
    ///
    /// `held` is the cards still in inventory, already filtered by `isHeld`.
    /// `marketCents` answers with a card's market value, or nil when the catalog
    /// has no price for it — the same contract as `InventoryModel.marketCents`.
    static func make(
        purchases: [Purchase],
        grading: [GradingSubmission],
        sales: [Sale],
        expenses: [BusinessExpense],
        held: [OwnedCard],
        marketCents: (OwnedCard) -> Int?
    ) -> LedgerSummary {
        var s = LedgerSummary()

        let entries = LedgerEntry.entries(purchases: purchases, grading: grading, sales: sales, expenses: expenses)
        for entry in entries {
            if entry.isMoneyIn { s.moneyInCents += entry.amountCents } else { s.moneyOutCents -= entry.amountCents }
        }

        s.orderCount = sales.count
        for sale in sales {
            s.revenueCents += sale.netCents
            if let gain = sale.realizedGainCents {
                s.realizedGainCents += gain
                s.ordersWithKnownBasis += 1
            }
        }

        // Grading is capitalised into `OwnedCard.gradingBasisCents`, so it
        // counts as a purchase here and comes back in ending inventory for
        // every card still held. Both sides or neither, or the P&L limps.
        s.purchasesCents = purchases.reduce(0) { $0 + $1.landedCostCents }
            + grading.reduce(0) { $0 + $1.totalCostCents }
        s.expensesCents = expenses.reduce(0) { $0 + $1.amountCents }
        // His first purchase is 2026-04-20 and the books start there, so this
        // is a fact rather than an estimate. docs/02-data-model.md.
        s.beginningInventoryCents = 0

        for card in held {
            let quantity = max(1, card.quantity)
            s.heldCardCount += quantity
            s.heldAtCostCents += card.totalBasisCents
            if Self.isAtGrader(card) { s.atGraderCount += quantity }
            if card.basisIsAllocated { s.allocatedCount += 1 }

            let market = (marketCents(card) ?? 0) * quantity
            s.heldAtMarketCents += market
            if !card.isBulk, marketCents(card) != nil, card.totalBasisCents > 0 {
                s.pricedMarketCents += market
                s.pricedBasisCents += card.totalBasisCents
            }
        }
        s.endingInventoryCents = s.heldAtCostCents

        return s
    }
}
