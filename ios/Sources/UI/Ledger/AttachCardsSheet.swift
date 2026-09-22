import SwiftData
import SwiftUI

/// Put inventory cards on an order that is on the books. Pick the cards, then
/// attach them. Each card gets the "sold" tag and leaves inventory.
///
/// With a `line`, the sheet links one card to a line that names a card and
/// links none. The order then does not count that card twice.
struct AttachCardsSheet: View {
    let sale: Sale
    var line: SaleLine?
    var onAttached: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(InventoryModel.self) private var model
    @Query private var cards: [OwnedCard]

    @State private var selection: [UUID] = []
    @State private var failed = false

    private var chosen: [OwnedCard] {
        let byId = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        return selection.compactMap { byId[$0] }
    }

    var body: some View {
        NavigationStack {
            InventoryCardPicker(selection: $selection, single: line != nil, recorded: line?.describedAs)
                .navigationTitle(line == nil ? "Attach cards" : "Link a card")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(line == nil ? "Attach" : "Link") { save(chosen) }
                            .disabled(selection.isEmpty)
                    }
                }
        }
        .alert("The cards were not attached", isPresented: $failed) {
            Button("OK") {}
        } message: {
            Text("The store did not accept the change. Try again.")
        }
    }

    private func save(_ picked: [OwnedCard]) {
        let items = picked.map { card in
            SaleEditor.Attachment(card: card, describedAs: card.displayName(model.hits[card.productId]) ?? "")
        }
        do {
            if let line, let item = items.first {
                try SaleEditor.link(line, to: item, context: modelContext)
            } else {
                try SaleEditor.attach(items, to: sale, context: modelContext)
            }
        } catch {
            failed = true
            return
        }
        onAttached()
        dismiss()
    }
}
