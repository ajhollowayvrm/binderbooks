import SwiftData
import SwiftUI

/// The second half of the ledger: profit, position, and cash.
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

    /// Cards still in inventory. A sold card keeps its row and its basis, so
    /// this filter is what stops every figure below from counting it.
    private var held: [OwnedCard] {
        cards.filter { $0.isCommitted && LedgerSummary.isHeld($0) }
    }

    private var summary: LedgerSummary {
        LedgerSummary.make(
            purchases: purchases, grading: grading, sales: sales, expenses: expenses,
            held: held, marketCents: { inventory.marketCents(for: $0) }
        )
    }

    var body: some View {
        let s = summary

        List {
            Section {
                signed("Realized on orders", s.realizedGainCents)
                LabeledContent("Orders counted") {
                    Text("\(s.ordersWithKnownBasis) of \(s.orderCount)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Profit")
            } footer: {
                if s.ordersWithUnknownBasis > 0 {
                    Text("\(s.ordersWithUnknownBasis) orders recorded a price and no card, so what they cost is not known and no gain is claimed for them.")
                } else {
                    Text("Every order has a cost behind it.")
                }
            }

            Section {
                row("Revenue", s.revenueCents)
                row("Beginning inventory", s.beginningInventoryCents)
                row("Purchases", s.purchasesCents)
                row("Ending inventory", s.endingInventoryCents)
                row("Cost of goods sold", s.costOfGoodsSoldCents)
                row("Expenses", s.expensesCents)
                signed("Profit", s.profitCents, weight: .bold)
            } header: {
                Text("Profit and loss")
            } footer: {
                Text("Revenue less cost of goods sold less expenses, over everything since your first purchase. Ending inventory counts what a card cost, and bulk has no cost, so it counts as nothing and this number reads low.")
            }

            Section {
                LabeledContent("Cards") {
                    Text("\(s.heldCardCount)")
                        .font(.body.monospacedDigit())
                }
                row("At cost", s.heldAtCostCents)
                row("At market", s.heldAtMarketCents)
                signed("Unrealized", s.unrealizedCents)
                if s.atGraderCount > 0 {
                    LabeledContent("At grader") {
                        Text("\(s.atGraderCount)")
                            .font(.body.monospacedDigit())
                    }
                }
            } header: {
                Text("What you hold")
            } footer: {
                Text(positionFootnote(s))
            }

            Section {
                row("Money in", s.moneyInCents)
                row("Money out", s.moneyOutCents)
                // The treatment the transaction list used, kept as it was: this
                // is the one figure that did not change, only moved.
                LabeledContent("Difference") {
                    Text(s.differenceCents.asCurrency)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(s.differenceCents >= 0 ? Color.green : Color.primary)
                }
            } header: {
                Text("Cash")
            } footer: {
                // The same warning the transaction list used to carry. It is
                // more needed here, beside a profit number it is not.
                Text("Cash in and out, not profit. What you bought and still hold is not a loss.")
            }
        }
        .task(id: cards.count) {
            await inventory.load(for: held)
        }
    }

    /// Sold cards are gone, so an allocated basis matters only for what is left.
    private func positionFootnote(_ s: LedgerSummary) -> String {
        let base = "Unrealized covers every card that has both a cost and a market price. Cards you have sold are not counted here."
        guard s.allocatedCount > 0 else { return base }
        return base + " \(s.allocatedCount) of these costs were split out of a purchase rather than paid for one card."
    }

    private func row(_ label: String, _ cents: Int) -> some View {
        LabeledContent(label) {
            Text(cents.asCurrency)
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
