import SwiftData
import SwiftUI

/// Cards from inventory onto one purchase. It is Choose a purchase from the
/// other side, for a purchase that has money on the books and no cards yet.
struct PurchaseCardsSheet: View {
    let purchase: Purchase
    var onLinked: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var cards: [OwnedCard]
    @State private var selection: [UUID] = []
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            InventoryCardPicker(
                selection: $selection,
                footer: "Sold cards are not on this list. A card on another purchase moves here, and both purchases split again."
            )
            .navigationTitle("Add cards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.disabled(selection.isEmpty)
                }
            }
            .alert("Added", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil; dismiss() } })) {
                Button("OK") {}
            } message: {
                Text(message ?? "")
            }
            .alert("The cards did not move", isPresented: $failed) {
                Button("OK") {}
            }
        }
    }

    private func add() {
        let byId = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        let chosen = selection.compactMap { byId[$0] }
        do {
            let result = try PurchaseLink.link(chosen, to: purchase, context: modelContext)
            onLinked()
            if !result.split {
                message = "A card on this purchase has a cost that the split did not write, so the total did not split again. Set the cost of the new cards by hand."
            } else {
                dismiss()
            }
        } catch {
            failed = true
        }
    }
}
