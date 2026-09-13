import SwiftData
import SwiftUI

/// Put inventory cards on an order that is on the books. The first page picks
/// the cards. The second page sets what each card cost, as `SellSheet` does.
/// Each card gets the "sold" tag and leaves inventory.
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
    @State private var pricing = false
    @State private var basisTexts: [UUID: String] = [:]
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
                        Button("Next") {
                            basisTexts = CardCostRows.seeded(chosen, basisTexts)
                            pricing = true
                        }
                        .disabled(selection.isEmpty)
                    }
                }
                .navigationDestination(isPresented: $pricing) { costForm }
        }
        .alert("The cards were not attached", isPresented: $failed) {
            Button("OK") {}
        } message: {
            Text("The store did not accept the change. Try again.")
        }
    }

    private var costForm: some View {
        let picked = chosen
        return Form {
            Section {
                CardCostRows(cards: picked, basisTexts: $basisTexts, name: name)
            } header: {
                Text("What the cards cost")
            } footer: {
                Text("What you paid for each card. A card left blank has no cost, and the order's gain is not known until it does.")
            }

            Section {
                LabeledContent("Net") {
                    Text(sale.netCents.asCurrency).font(.body.weight(.semibold).monospacedDigit())
                }
                LabeledContent("Gain") { GainText(cents: gainCents(picked)) }
            } footer: {
                if sale.lines.contains(where: { $0.id != line?.id }) {
                    Text("The gain also counts the cards that are on this order already.")
                }
            }
        }
        .navigationTitle(picked.count == 1 ? "1 card" : "\(picked.count) cards")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(line == nil ? "Attach" : "Link") { save(picked) }
                    .disabled(picked.isEmpty)
            }
        }
    }

    private func name(_ card: OwnedCard) -> String {
        card.displayName(model.hits[card.productId]) ?? "Card"
    }

    /// The gain the order shows after the save. The line to link is replaced,
    /// so its old "no cost" does not count.
    private func gainCents(_ picked: [OwnedCard]) -> Int? {
        let kept = sale.lines.filter { $0.id != line?.id }
        let typed = CardCostRows.typedCents(picked, basisTexts)
        guard !picked.isEmpty, kept.allSatisfy({ !$0.basisIncomplete }), typed.allSatisfy({ $0 != nil }) else { return nil }
        return sale.netCents - kept.reduce(0) { $0 + $1.basisCents } - typed.compactMap { $0 }.reduce(0, +)
    }

    private func save(_ picked: [OwnedCard]) {
        let items = zip(picked, CardCostRows.typedCents(picked, basisTexts)).map { card, cents in
            SaleEditor.Attachment(card: card, describedAs: card.displayName(model.hits[card.productId]) ?? "", basisCents: cents)
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
