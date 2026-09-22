import SwiftData
import SwiftUI

/// The copies behind one stacked line: nine Destined Rivals packs, each with
/// its own cost and its own pack to rip, or two copies of a card with one of
/// them listed.
///
/// The page collapses copies into one cell so it reads as inventory instead of
/// nine identical tiles, and this is where the nine come back. The cell's card
/// is the only thing the route carries; the membership is derived again here,
/// so a copy ripped, sold or deleted while this screen is open drops out of
/// the list on its own.
struct CardStackView: View {
    /// The copy the cell drew.
    let leadCardID: UUID

    @Environment(InventoryModel.self) private var model
    @Query private var cards: [OwnedCard]

    var body: some View {
        // No chips and no query: the copies of this card, whatever the page
        // was filtered to when he tapped it.
        let rows = model.rows(from: cards, applyFilter: false)
        let stack = InventoryStack.stack(of: leadCardID, in: rows)
        Group {
            if let stack {
                list(stack)
            } else {
                ContentUnavailableView {
                    Label("Not in inventory", systemImage: "tray")
                } description: {
                    Text("Every copy was sold, ripped, or deleted.")
                }
            }
        }
        .navigationTitle(stack?.lead.name ?? "Copies")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func list(_ stack: InventoryStack) -> some View {
        List {
            Section {
                LabeledContent("Copies", value: "\(stack.copies)")
                if let total = stack.totalValueCents {
                    LabeledContent("Value", value: total.asCurrency)
                }
                LabeledContent("Cost", value: stack.totalBasisCents.asCurrency)
                if let gain = stack.unrealizedCents {
                    LabeledContent("Unrealized") {
                        Text((gain >= 0 ? "+" : "−") + abs(gain).asCurrency)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(gain >= 0 ? .green : .red)
                    }
                }
            } footer: {
                Text("Every copy, added up. Cost counts the share each one carries of what its purchase cost.")
            }

            if !stack.mixedLabels.isEmpty {
                Section {
                    ForEach(stack.mixedLabels, id: \.self) { mixed in
                        LabeledContent(mixed.label, value: "\(mixed.copies) of \(stack.copies)")
                    }
                } header: {
                    Text("Not the same on every copy").textCase(nil)
                } footer: {
                    Text("Each copy below shows its own labels.")
                }
            }

            Section {
                // One row per copy, and each one pushes its own card: the cost,
                // the source purchase, the tags and Rip all live there.
                ForEach(stack.rows) { row in
                    NavigationLink(value: AppRoute.ownedCard(row.card.id)) {
                        OwnedCardRow(row: row)
                    }
                }
            } header: {
                Text("Each copy").textCase(nil)
            }
        }
        .listStyle(.plain)
    }
}
