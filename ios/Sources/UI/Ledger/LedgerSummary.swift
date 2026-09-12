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

/// The outcome to assume for every card out at a grader.
enum GradeAssumption: String, CaseIterable, Identifiable {
    case ten = "10"
    case nine = "9"
    case eight = "8"
    case low = "Low"

    var id: String { rawValue }

    /// The grade number to price at. `low` prices at his worst figure instead,
    /// whatever grade that is, so it has no number of its own.
    var gradeNumber: Double? {
        switch self {
        case .ten: return 10
        case .nine: return 9
        case .eight: return 8
        case .low: return nil
        }
    }

    /// What the row calls it. "10" covers a CGC Pristine 10 too, because both
    /// are grade 10 and the better figure wins.
    var title: String { rawValue }
}

/// What the cards at a grader do to the books if they all come back at one grade.
///
/// He has real money in a pile whose value is unknown, and the question that
/// follows is whether the best case clears the hole. This answers it with his own
/// comps and his own fee rate. Nothing here is a forecast — it is arithmetic on
/// figures he typed.
struct GradingOutlook: Equatable {
    /// One card's part of the outlook.
    ///
    /// A total he cannot take apart is a total he cannot act on, so the lines
    /// show which cards carry it and which pull it down. They add up to the
    /// cent: the selling cost splits over the priced cards by value, so the
    /// nets sum to `netCents` and the contributions to
    /// `profitAfterCents − profitTodayCents`.
    struct Line: Equatable, Identifiable {
        var cardId: UUID
        var productId: Int
        /// Nil when the card's label names no grader the app knows.
        var grader: String?
        /// The comp the line priced at, as he keyed it: "PSA 10". Nil when the
        /// card has no figure at this grade.
        var compKey: String?
        var costCents: Int
        var grossCents: Int?
        var feeCents = 0

        var id: UUID { cardId }
        var isPriced: Bool { grossCents != nil }
        var netCents: Int? { grossCents.map { $0 - feeCents } }
        /// What the card does to profit after: its net, less what it cost. An
        /// unpriced card counts as nothing, so it takes away its whole cost.
        var contributionCents: Int { (netCents ?? 0) - costCents }
    }

    var assumption: GradeAssumption = .ten
    var cardCount = 0
    /// How many of those carry a figure at this grade. It moves with the grade,
    /// and a reader who cannot see it will mistake a gap in his comps for a
    /// collapse in value.
    var pricedCount = 0
    var costCents = 0
    var grossCents = 0
    var netCents = 0
    var profitTodayCents = 0
    /// Every card at the grader, worst contribution first.
    var lines: [Line] = []

    var unpricedCount: Int { cardCount - pricedCount }
    var feeCents: Int { grossCents - netCents }

    /// Selling a card moves its proceeds into revenue and takes its cost out of
    /// ending inventory. In `revenue − (beginning + purchases − ending)` that is
    /// `+net` and `−cost`, so the whole scenario is one addition.
    var profitAfterCents: Int { profitTodayCents + netCents - costCents }

    /// What the net would have to reach for the books to come back to zero.
    var breakEvenNetCents: Int { costCents - profitTodayCents }

    var breaksEven: Bool { profitAfterCents >= 0 }
}

extension LedgerSummary {
    /// `atGrader` is the held cards out at a grader, already filtered.
    static func outlook(
        assumption: GradeAssumption,
        atGrader: [OwnedCard],
        profitTodayCents: Int,
        costs: SellingCosts
    ) -> GradingOutlook {
        var out = GradingOutlook(assumption: assumption, profitTodayCents: profitTodayCents)
        var lines: [GradingOutlook.Line] = []

        for card in atGrader {
            out.cardCount += 1
            out.costCents += card.totalBasisCents

            // The grader comes from the card's label. `graderRaw` is only set
            // when a card comes back, and these have not.
            let grader = GradedComps.graderAtGrader(tags: card.tags)
            var line = GradingOutlook.Line(cardId: card.id, productId: card.productId, grader: grader, costCents: card.totalBasisCents)
            if let grader {
                let comps = card.effectiveCompCents
                let comp = assumption.gradeNumber.map { GradedComps.comp(at: $0, for: grader, in: comps) }
                    ?? GradedComps.lowestComp(for: grader, in: comps)
                if let comp {
                    line.compKey = comp.key
                    line.grossCents = comp.cents
                    out.pricedCount += 1
                    out.grossCents += comp.cents
                }
            }
            lines.append(line)
        }

        out.netCents = costs.net(out.grossCents)

        // The total fee, split over the priced cards by value, so the lines
        // sum to the section to the cent.
        let priced = lines.indices.filter { lines[$0].isPriced }
        let fees = Allocation.splitByWeight(out.feeCents, weights: priced.map { lines[$0].grossCents ?? 0 })
        for (index, fee) in zip(priced, fees) {
            lines[index].feeCents = fee
        }
        out.lines = lines.sorted {
            $0.contributionCents == $1.contributionCents
                ? $0.cardId.uuidString < $1.cardId.uuidString
                : $0.contributionCents < $1.contributionCents
        }
        return out
    }
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
