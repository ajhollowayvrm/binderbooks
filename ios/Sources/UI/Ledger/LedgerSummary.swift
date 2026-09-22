import Foundation

/// What the books say, over the whole period and over the whole business.
///
/// The ledger answers "what happened". This answers AJ's questions, in his
/// words of 2026-09-22: what do I have, what have I spent, what have I earned,
/// and what is the potential. Grading potential he judges himself, from the
/// comps on each card.
///
/// It totals and it does not slice. No vendor, no set, no product, no channel —
/// decision 23 in docs/00-brief.md, amended 2026-09-11 to allow the totals and
/// the P&L and nothing else. Every number here is arithmetic over the store, so
/// there is no stored `PeriodSummary` that could disagree with it.
struct LedgerSummary: Equatable {
    // Cash, the three rows that used to sit on top of the transaction list.
    var moneyInCents = 0
    var moneyOutCents = 0

    // The P&L: money in less money out, by kind.
    /// Every order's net: gross and shipping charged, less fees, sales tax,
    /// and the shipping he paid.
    var revenueCents = 0
    /// What every purchase landed at.
    var purchasesCents = 0
    /// What every grading charge cost.
    var gradingCents = 0
    var expensesCents = 0

    // What he has. The cards he could sell, and the personal collection
    // apart, because he keeps those.
    var heldCardCount = 0
    var heldAtMarketCents = 0
    var personalCardCount = 0
    var personalAtMarketCents = 0
    /// Every held card out at a grader, the personal collection too.
    var atGraderCount = 0

    /// Everything that went out: purchases, grading, and expenses.
    var spentCents: Int { purchasesCents + gradingCents + expensesCents }

    var differenceCents: Int { moneyInCents - moneyOutCents }

    /// Earned less spent. A card he still holds counts as nothing here, so
    /// this equals `differenceCents`.
    var profitCents: Int { revenueCents - spentCents }

    /// The profit if he sold every card he holds today at market, less the
    /// selling costs.
    func ifSoldTodayCents(_ costs: SellingCosts) -> Int {
        profitCents + costs.net(heldAtMarketCents)
    }
}

extension LedgerSummary {
    /// Whether a card is still inventory he holds.
    ///
    /// A sold card keeps its row, so anything totalling value must drop it by
    /// hand. Miss this and the position is inflated by everything he has ever
    /// sold.
    ///
    /// Sold is `CardTagIndex.isSold`, the same predicate the inventory uses, so
    /// a card cannot be off the inventory page and inside the position at the
    /// same time. A written-off card is gone too, and the ledger is the
    /// only place that cares about the difference.
    static func isHeld(_ card: OwnedCard) -> Bool {
        if CardTagIndex.isSold(card) { return false }
        return !CardTagIndex.has(ReservedTag.lost, on: card) && card.status != .lost
    }

    /// A card out at a grader, by either signal, for the same reason.
    ///
    /// The label wins. The status is the older signal, and an imported card
    /// kept `statusRaw` at `atGrader` after "Mark graded" took its label off.
    /// So the status counts only for a card with no sign it came back: no
    /// "graded" label and no grade. A slab sent back for a regrade wears the
    /// label again, so the label check still finds it.
    static func isAtGrader(_ card: OwnedCard) -> Bool {
        if ReservedTag.allAtGrader.contains(where: { CardTagIndex.has($0, on: card) }) { return true }
        guard card.status == .atGrader else { return false }
        return !CardTagIndex.has(ReservedTag.graded, on: card) && card.gradeLabel == nil
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

        s.revenueCents = sales.reduce(0) { $0 + $1.netCents }
        s.purchasesCents = purchases.reduce(0) { $0 + $1.landedCostCents }
        s.gradingCents = grading.reduce(0) { $0 + $1.totalCostCents }
        s.expensesCents = expenses.reduce(0) { $0 + $1.amountCents }

        for card in held {
            let quantity = max(1, card.quantity)
            if Self.isAtGrader(card) { s.atGraderCount += quantity }
            // His call, 2026-09-22: a card he keeps is not for sale, so it
            // does not count in what he could sell today.
            if card.isPersonalCollection {
                s.personalCardCount += quantity
                s.personalAtMarketCents += (marketCents(card) ?? 0) * quantity
            } else {
                s.heldCardCount += quantity
                s.heldAtMarketCents += (marketCents(card) ?? 0) * quantity
            }
        }

        return s
    }
}
