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
    @AppStorage(SellingCostsKey.defaultsKey) private var costOverride = ""
    @State private var assumption: GradeAssumption = LedgerSummaryView.debugAssumption

    /// Cards still in inventory. A sold card keeps its row and its basis, so
    /// this filter is what stops every figure below from counting it.
    private var held: [OwnedCard] {
        cards.filter { $0.isCommitted && LedgerSummary.isHeld($0) }
    }

    private var atGrader: [OwnedCard] { held.filter(LedgerSummary.isAtGrader) }

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
        ScrollViewReader { proxy in
            list
                .task {
                    // simctl cannot scroll, and the outlook sits below the P&L.
                    // `CT_OPEN_LEDGER=outlook` brings it into view.
                    #if DEBUG
                    guard ProcessInfo.processInfo.environment["CT_OPEN_LEDGER"] == "outlook" else { return }
                    try? await Task.sleep(for: .milliseconds(600))
                    withAnimation { proxy.scrollTo(Self.outlookAnchor, anchor: .top) }
                    #endif
                }
        }
    }

    static let outlookAnchor = "outlook"

    /// Screenshot state for the grade picker. simctl cannot tap a segment.
    /// `CT_GRADE=9` opens on 9. Always `.ten` outside DEBUG.
    static var debugAssumption: GradeAssumption {
        #if DEBUG
        let raw = ProcessInfo.processInfo.environment["CT_GRADE"] ?? ""
        return GradeAssumption(rawValue: raw) ?? .ten
        #else
        .ten
        #endif
    }

    private var list: some View {
        let s = summary

        return List {
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

            outlookSection(profitToday: s.profitCents)

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
                        Text("\(s.atGraderCount) cards")
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

    /// What the cards at a grader do to the books if they all come back at one
    /// grade. Nothing shows when none are out.
    @ViewBuilder private func outlookSection(profitToday: Int) -> some View {
        let o = LedgerSummary.outlook(
            assumption: assumption, atGrader: atGrader,
            profitTodayCents: profitToday, costs: costs
        )

        if o.cardCount > 0 {
            Section {
                Picker("Grade", selection: $assumption) {
                    ForEach(GradeAssumption.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))

                LabeledContent("At a grader") {
                    Text("\(o.cardCount) cards")
                        .font(.body.monospacedDigit())
                }
                // The count is the honesty of the section. Coverage moves with
                // the grade, so without it a gap in his comps reads as a
                // collapse in value.
                LabeledContent("Priced at this grade") {
                    Text("\(o.pricedCount) of \(o.cardCount)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(o.unpricedCount > 0 ? Color.orange : Color.secondary)
                }
                row("Their cost", o.costCents)
                row("Value at this grade", o.grossCents)
                LabeledContent("Selling costs (\(costs.percentText))") {
                    Text("−" + o.feeCents.asCurrency)
                        .font(.body.monospacedDigit())
                }
                row("Net proceeds", o.netCents)
                signed("Profit today", o.profitTodayCents)
                signed("Profit after", o.profitAfterCents, weight: .bold)
            } header: {
                Text("If everything grades \(assumption.title)")
            } footer: {
                Text(outlookFootnote(o))
            }
            .id(Self.outlookAnchor)
        }
    }

    private func outlookFootnote(_ o: GradingOutlook) -> String {
        var parts: [String] = []
        parts.append(o.breaksEven
            ? "Break even, with \(o.profitAfterCents.asCurrency) to spare."
            : "Short by \(abs(o.profitAfterCents).asCurrency). You would need \(o.breakEvenNetCents.asCurrency) net.")
        if o.unpricedCount > 0 {
            parts.append("\(o.unpricedCount) cards have no figure at this grade and count as nothing here. Enter their comps to see the real number.")
        }
        parts.append("Selling costs come from your own orders. Change the rate in Settings.")
        return parts.joined(separator: " ")
    }

    /// Sold cards are gone, so an allocated basis matters only for what is left.
    private func positionFootnote(_ s: LedgerSummary) -> String {
        var parts = ["Unrealized covers every card that has both a cost and a market price. Cards you have sold are not counted here."]
        if s.allocatedCount > 0 {
            parts.append("\(s.allocatedCount) of these costs were split out of a purchase rather than paid for one card.")
        }
        if s.atGraderCount > 0 {
            // Their market figure is the raw print, not the slab. Saying so
            // beats quietly swapping in a projection, which would put a guess
            // inside a position figure.
            parts.append("Cards at a grader count at the raw print's price. What they might come back worth is above.")
        }
        return parts.joined(separator: " ")
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
