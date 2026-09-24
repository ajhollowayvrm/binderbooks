import SwiftData
import SwiftUI

/// The second half of the ledger: AJ's questions, one section each, in his
/// order of 2026-09-22. What do I have, what have I spent, what have I earned,
/// where does that leave me, and what is the potential.
///
/// Grading potential sits in the potential, as his own comps: a slab that
/// came back counts at its grade's comp, and a card still at a grader gives a
/// low and a best figure. There is no grade picker; he judges the grade.
///
/// Every figure covers the whole business over the whole period. Nothing here
/// is broken down by vendor, set, or product — decision 23.
struct LedgerSummaryView: View {
    var purchases: [Purchase]
    var grading: [GradingSubmission]
    var sales: [Sale]
    var expenses: [BusinessExpense]

    @Environment(InventoryModel.self) private var inventory
    @Query private var cards: [OwnedCard]
    @AppStorage(SellingCostsKey.defaultsKey) private var costOverride = ""

    /// Cards still in inventory. A sold card keeps its row, so this filter is
    /// what stops every figure below from counting it.
    private var held: [OwnedCard] {
        cards.filter { $0.isCommitted && LedgerSummary.isHeld($0) }
    }

    private var summary: LedgerSummary {
        LedgerSummary.make(
            purchases: purchases, grading: grading, sales: sales, expenses: expenses,
            held: held, marketCents: { inventory.marketCents(for: $0) }
        )
    }

    private var costs: SellingCosts {
        SellingCostsKey.effective(
            override: SellingCostsKey.basisPoints(from: costOverride),
            derived: ChannelRates.derived(from: sales)
        )
    }

    var body: some View {
        let s = summary

        List {
            Section {
                count("Cards to sell", s.heldCardCount)
                row("At market", s.heldAtMarketCents)
                if s.personalCardCount > 0 {
                    count("Personal collection", s.personalCardCount)
                    row("At market", s.personalAtMarketCents)
                }
                if s.atGraderCount > 0 {
                    count("At a grader", s.atGraderCount)
                }
                if s.onOrderCount > 0 {
                    count("On order", s.onOrderCount)
                }
            } header: {
                Text("What you have")
            } footer: {
                Text(haveFootnote(s))
            }

            Section {
                row("Purchases", s.purchasesCents)
                row("Grading", s.gradingCents)
                row("Expenses", s.expensesCents)
                row("Spent", s.spentCents, weight: .bold)
            } header: {
                Text("What you spent")
            }

            Section {
                row("Sales, net", s.revenueCents, weight: .bold)
            } header: {
                Text("What you earned")
            } footer: {
                Text("What your orders brought in, after marketplace fees, sales tax, and the shipping you paid.")
            }

            Section {
                signed("Earned less spent", s.profitCents, weight: .bold)
            } header: {
                Text("Where you are")
            } footer: {
                Text("The cards you still hold count as nothing here. What they could bring is below.")
            }

            Section {
                row("Cards to sell, at market", s.heldAtMarketCents)
                deduction("Selling costs (\(costs.percentText))", s.heldAtMarketCents - costs.net(s.heldAtMarketCents))
                signed("If you sold today", s.ifSoldTodayCents(costs), weight: .bold)
                if s.atGraderWithCompsCount > 0 {
                    signed("If graded cards come back low", s.ifGradedLowCents(costs))
                    signed("If graded cards come back best", s.ifGradedHighCents(costs), weight: .bold)
                }
            } header: {
                Text("The potential")
            } footer: {
                Text(potentialFootnote(s))
            }
        }
        .task(id: cards.count) {
            await inventory.load(for: held)
        }
    }

    private func haveFootnote(_ s: LedgerSummary) -> String {
        var parts = ["Market value comes from the catalog's prices. A graded card that came back counts at your comp for its grade. Sold cards are not counted."]
        if s.atGraderCount > 0 {
            // Their market figure is the raw print, not the slab. What they
            // could come back worth is in the potential, as a range.
            parts.append("Cards at a grader count at the raw print's price here.")
        }
        if s.onOrderCount > 0 {
            parts.append("Cards on order are paid for under Purchases and count here once you mark them received.")
        }
        return parts.joined(separator: " ")
    }

    private func potentialFootnote(_ s: LedgerSummary) -> String {
        var parts = ["Where you are, plus what the cards to sell would bring, less your selling costs. Your personal collection is not counted."]
        if s.atGraderWithCompsCount > 0 {
            parts.append("\"Come back low\" counts each card at a grader at your lowest comp for that grader. \"Best\" counts it at your best comp.")
        }
        if s.atGraderWithoutCompsCount > 0 {
            parts.append("\(s.atGraderWithoutCompsCount) \(s.atGraderWithoutCompsCount == 1 ? "card" : "cards") at a grader \(s.atGraderWithoutCompsCount == 1 ? "has" : "have") no comps and count at the raw price. Enter comps on the card to include them.")
        }
        parts.append("Selling costs come from your own orders. Change the rate in Settings.")
        return parts.joined(separator: " ")
    }

    private func count(_ label: String, _ cards: Int) -> some View {
        LabeledContent(label) {
            Text("\(cards) \(cards == 1 ? "card" : "cards")")
                .font(.body.monospacedDigit())
        }
    }

    private func row(_ label: String, _ cents: Int, weight: Font.Weight = .regular) -> some View {
        LabeledContent(label) {
            Text(cents.asCurrency)
                .font(.body.monospacedDigit().weight(weight))
        }
    }

    /// An amount that comes off the figure above it.
    private func deduction(_ label: String, _ cents: Int) -> some View {
        LabeledContent(label) {
            Text("−" + cents.asCurrency)
                .font(.body.monospacedDigit())
        }
    }

    /// A number that can go either way reads with its sign and its colour.
    private func signed(_ label: String, _ cents: Int, weight: Font.Weight = .regular) -> some View {
        LabeledContent(label) {
            Text((cents >= 0 ? "+" : "−") + abs(cents).asCurrency)
                .font(.body.monospacedDigit().weight(weight))
                .foregroundStyle(cents >= 0 ? Color.green : Color.red)
        }
    }
}
