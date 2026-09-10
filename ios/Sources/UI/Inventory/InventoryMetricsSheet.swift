import SwiftUI

/// The money, behind a button. The landing page is for cards; the numbers are
/// something he opens when he wants them.
///
/// It reports what the current filters and the current query left on the page,
/// not the whole store, so the figures always match the cards behind the sheet.
struct InventoryMetricsSheet: View {
    var summary: InventorySummary
    var rowCount: Int

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("Cards", "\(summary.cardCount)")
                    row("Lines", "\(rowCount)")
                } footer: {
                    Text("A bulk line counts every copy in \"Cards\" and once in \"Lines\".")
                }

                Section("Value") {
                    row("Market", summary.marketCents.asCurrency)
                    row("Basis", summary.basisCents.asCurrency)
                }

                if summary.pricedBasisCents > 0 || summary.pricedMarketCents > 0 {
                    Section {
                        row(
                            "Unrealized",
                            (summary.unrealizedCents >= 0 ? "+" : "−") + abs(summary.unrealizedCents).asCurrency,
                            color: summary.unrealizedCents >= 0 ? .green : .red
                        )
                        row("Priced market", summary.pricedMarketCents.asCurrency)
                        row("Priced basis", summary.pricedBasisCents.asCurrency)
                    } footer: {
                        if summary.allocatedCount > 0 {
                            Text("Unrealized covers every card that has both a cost and a market price. \(summary.allocatedCount) of those costs were split out of a purchase rather than paid for one card.")
                        } else {
                            Text("Unrealized covers every card that has both a cost and a market price.")
                        }
                    }
                }
            }
            .navigationTitle("Metrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
        }
    }
}
