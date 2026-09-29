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
///
/// The page ticks a stacked line as one: every copy. This screen ticks one
/// copy at a time, so he can list one of four copies while two are at PSA.
/// AJ's call, 2026-09-28. The selection is this screen's own, so it ends when
/// he goes back and never leaks onto the page.
struct CardStackView: View {
    /// The copy the cell drew.
    let leadCardID: UUID

    @Environment(InventoryModel.self) private var model
    @Environment(\.modelContext) private var modelContext
    @Query private var cards: [OwnedCard]
    @State private var copySelection = InventorySelection()
    /// What the copies share, kept from the first draw. He can sell or delete
    /// the lead copy from here, and the other copies must stay on screen.
    @State private var stackKey: InventoryStack.Key?

    var body: some View {
        // No chips and no query: the copies of this card, whatever the page
        // was filtered to when he tapped it.
        let rows = model.rows(from: cards, applyFilter: false)
        let stack = stackKey.flatMap { InventoryStack.stack(key: $0, in: rows) }
            ?? InventoryStack.stack(of: leadCardID, in: rows)
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
        .inventorySelectionChrome(rows: stack?.rows ?? [])
        .toolbar {
            // While he selects, the chrome holds Select all, the count, and
            // Done, and these step aside.
            if !copySelection.isSelecting, stack?.isStacked == true {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Select") { copySelection.start() }
                }
            }
            if !copySelection.isSelecting, let lead = stack?.lead.card, CardEditor.canAddCopy(of: lead) {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        // The list derives the copies again, so the new one
                        // appears in it on its own.
                        try? CardEditor.addCopy(of: lead, context: modelContext)
                        model.invalidateHaystacks()
                    } label: {
                        Label("Add another", systemImage: "plus")
                    }
                }
            }
        }
        .environment(copySelection)
        .onAppear {
            if stackKey == nil, let lead = cards.first(where: { $0.id == leadCardID }) {
                stackKey = InventoryStack.key(for: lead)
            }
        }
    }

    private func list(_ stack: InventoryStack) -> some View {
        List {
            Section {
                LabeledContent("Copies", value: "\(stack.copies)")
                if let total = stack.totalValueCents {
                    LabeledContent("Value", value: total.asCurrency)
                }
            } footer: {
                Text("Every copy, added up.")
            }

            // One section per set of labels, so the two copies at PSA sit
            // apart from the two he can still list.
            ForEach(stack.labelGroups) { group in
                Section {
                    // A tap pushes the copy: the cost, the source purchase,
                    // the tags and Rip all live there. A long press, or
                    // Select, ticks copies one by one.
                    ForEach(group.rows) { row in
                        SelectableStackRow(stack: InventoryStack(rows: [row]))
                    }
                } header: {
                    Text(stack.labelGroups.count == 1 ? "Each copy" : "\(group.title) · \(group.copies)")
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
    }
}
