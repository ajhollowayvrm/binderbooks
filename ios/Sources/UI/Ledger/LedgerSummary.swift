import Foundation

/// What the books say, since the books start, over the whole business.
///
/// The ledger answers "what happened". This answers AJ's questions, in his
/// words of 2026-09-22: what do I have, what have I spent, what have I earned,
/// and what is the potential, grading included, from his own comps.
///
/// Since 2026-09-25 the money counts only from the start of the books, and a
/// card has a cost again. See `Books` and `CostBasis`.
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

    // Cost. See `CostBasis`.
    /// What the cards to sell cost. The personal collection is apart.
    var heldAtCostCents = 0
    /// What the cards on the orders cost.
    var soldCostCents = 0
    /// Order lines that name a card and link none. Their cost is unknown, so
    /// the gain on the orders reads high by their cost.
    var soldLinesWithoutCardCount = 0

    // What he has. The cards he could sell, and the personal collection
    // apart, because he keeps those.
    var heldCardCount = 0
    var heldAtMarketCents = 0
    var personalCardCount = 0
    var personalAtMarketCents = 0
    /// Every held card out at a grader, the personal collection too.
    var atGraderCount = 0

    // Grading. A slab that came back counts at his comp for its grade, in
    // `heldAtMarketCents` too. A card still at a grader makes a range: his
    // lowest comp for that grader to his best. He judges the grade himself,
    // so the range is his own figures, not a forecast.
    /// The cards to sell, with every card at a grader at its lowest comp.
    var gradedLowCents = 0
    /// The same, at its best comp.
    var gradedHighCents = 0
    /// Cards to sell that are at a grader and carry comps for it.
    var atGraderWithCompsCount = 0
    /// Cards to sell that are at a grader with no comps. They count at the
    /// raw print's price in both figures.
    var atGraderWithoutCompsCount = 0

    /// Everything that went out: purchases, grading, and expenses.
    var spentCents: Int { purchasesCents + gradingCents + expensesCents }

    var differenceCents: Int { moneyInCents - moneyOutCents }

    /// Earned less spent. A card he still holds counts as nothing here, so
    /// this equals `differenceCents`.
    var profitCents: Int { revenueCents - spentCents }

    /// What the orders brought in, less what their cards cost.
    var gainOnSalesCents: Int { revenueCents - soldCostCents }

    /// The profit if he sold every card he holds today at market, less the
    /// selling costs.
    func ifSoldTodayCents(_ costs: SellingCosts) -> Int {
        profitCents + costs.net(heldAtMarketCents)
    }

    /// The profit if every card at a grader comes back at its lowest comp,
    /// and he then sells every card to sell.
    func ifGradedLowCents(_ costs: SellingCosts) -> Int {
        profitCents + costs.net(gradedLowCents)
    }

    /// The same, with every card at a grader at its best comp.
    func ifGradedHighCents(_ costs: SellingCosts) -> Int {
        profitCents + costs.net(gradedHighCents)
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

    /// What one card is worth now. A slab that came back counts at his comp
    /// for the grade it got. Everything else, and a slab with no comp for its
    /// grade, counts at the catalog's price.
    static func valueCents(_ card: OwnedCard, marketCents: (OwnedCard) -> Int?) -> Int {
        if let graded = GradedComps.value(grader: card.graderRaw, grade: card.gradeLabel, in: card.effectiveCompCents) {
            return graded
        }
        return marketCents(card) ?? 0
    }

    /// Cash and profit, from the money rows alone.
    ///
    /// `held` is the cards still in inventory, already filtered by `isHeld`.
    /// `marketCents` answers with a card's market value, or nil when the catalog
    /// has no price for it — the same contract as `InventoryModel.marketCents`.
    ///
    /// `since` is the start of the books. A row dated before it is left out.
    /// Nil counts every row.
    static func make(
        purchases: [Purchase],
        grading: [GradingSubmission],
        sales: [Sale],
        expenses: [BusinessExpense],
        held: [OwnedCard],
        since start: Date? = nil,
        marketCents: (OwnedCard) -> Int?
    ) -> LedgerSummary {
        var s = LedgerSummary()

        let shares = CostBasis.gradingShares(grading, since: start)
        let purchases = purchases.filter { Books.counts($0.date, since: start) }
        let grading = grading.filter { Books.counts(Books.date(of: $0), since: start) }
        let sales = sales.filter { Books.counts($0.soldAt, since: start) }
        let expenses = expenses.filter { Books.counts($0.date, since: start) }

        let entries = LedgerEntry.entries(purchases: purchases, grading: grading, sales: sales, expenses: expenses)
        for entry in entries {
            if entry.isMoneyIn { s.moneyInCents += entry.amountCents } else { s.moneyOutCents -= entry.amountCents }
        }

        s.revenueCents = sales.reduce(0) { $0 + $1.netCents }
        s.purchasesCents = purchases.reduce(0) { $0 + $1.landedCostCents }
        s.gradingCents = grading.reduce(0) { $0 + $1.totalCostCents }
        s.expensesCents = expenses.reduce(0) { $0 + $1.amountCents }

        for line in sales.flatMap(\.lines) {
            if let card = line.card {
                s.soldCostCents += CostBasis.cost(of: card, grading: shares)
            } else if !line.describedAs.isEmpty {
                s.soldLinesWithoutCardCount += 1
            }
        }

        for card in held {
            let quantity = max(1, card.quantity)
            if Self.isAtGrader(card) { s.atGraderCount += quantity }
            // His call, 2026-09-22: a card he keeps is not for sale, so it
            // does not count in what he could sell today.
            let value = Self.valueCents(card, marketCents: marketCents) * quantity
            if card.isPersonalCollection {
                s.personalCardCount += quantity
                s.personalAtMarketCents += value
                continue
            }
            s.heldCardCount += quantity
            s.heldAtMarketCents += value
            s.heldAtCostCents += CostBasis.cost(of: card, grading: shares)

            if Self.isAtGrader(card) {
                let grader = GradedComps.graderAtGrader(tags: card.tags)
                if let grader, let range = GradedComps.range(for: grader, in: card.effectiveCompCents) {
                    s.atGraderWithCompsCount += quantity
                    s.gradedLowCents += range.lowerBound * quantity
                    s.gradedHighCents += range.upperBound * quantity
                    continue
                }
                s.atGraderWithoutCompsCount += quantity
            }
            s.gradedLowCents += value
            s.gradedHighCents += value
        }

        return s
    }
}
