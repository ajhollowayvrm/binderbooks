import SwiftUI

/// The money, behind a button. The landing page is for cards; the numbers are
/// something he opens when he wants them.
///
/// It reports what the current filters and the current query left on the page,
/// not the whole store, so the figures always match the cards behind the sheet.
struct InventoryMetricsSheet: View {
    var summary: InventorySummary
    /// Lines on the page, not cards: copies of one thing are one line.
    var lineCount: Int

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("Cards", "\(summary.cardCount)")
                    row("Lines", "\(lineCount)")
                } footer: {
                    Text("Copies of the same card are one line. A bulk line counts every copy in \"Cards\" and once in \"Lines\".")
                }

                Section("Value") {
                    row("Value", summary.marketCents.asCurrency)
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
