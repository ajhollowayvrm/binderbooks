import SwiftData
import SwiftUI

/// The inventory list to tick the sold cards on. The attach sheet and the add
/// sheet both use it. Put it inside a `NavigationStack`, for the search field.
struct InventoryCardPicker: View {
    /// In the order of the taps, so the cost fields list the cards that way.
    @Binding var selection: [UUID]
    /// True when only one card can be ticked.
    var single = false
    /// What the order recorded, for a line that links no card.
    var recorded: String?
    var footer = "Sold cards are not on this list. One card can be on one order only."

    @Environment(InventoryModel.self) private var model
    @Query(sort: \OwnedCard.acquiredAt, order: .reverse) private var cards: [OwnedCard]
    @State private var query = ""

    var body: some View {
        // Sold cards are already gone from these rows.
        let available = model.rows(from: cards, query: query, applyFilter: false)
        List {
            if let recorded, !recorded.isEmpty {
                Section("The order recorded") {
                    Text(recorded)
                }
            }

            Section {
                if available.isEmpty {
                    Text(query.isEmpty ? "No cards are in inventory." : "No card in inventory matches.")
                        .foregroundStyle(.secondary)
                }
                ForEach(available) { row in
                    Button {
                        toggle(row.card.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selection.contains(row.card.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection.contains(row.card.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                            OwnedCardRow(row: row)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                if !single {
                    Text("\(selection.count) selected")
                }
            } footer: {
                Text(footer)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search inventory")
        .task { await model.load(for: cards) }
    }

    private func toggle(_ id: UUID) {
        if single {
            selection = selection == [id] ? [] : [id]
        } else if let index = selection.firstIndex(of: id) {
            selection.remove(at: index)
        } else {
            selection.append(id)
        }
    }
}

/// Picks the cards for an order that is not saved yet. The order saves them.
struct PickCardsSheet: View {
    var onDone: ([OwnedCard]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query private var cards: [OwnedCard]
    @State private var selection: [UUID]

    init(initial: [UUID], onDone: @escaping ([OwnedCard]) -> Void) {
        self.onDone = onDone
        _selection = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            InventoryCardPicker(selection: $selection)
                .navigationTitle("Attach cards")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            let byId = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
                            onDone(selection.compactMap { byId[$0] })
                            dismiss()
                        }
                    }
                }
        }
    }
}

/// One cost field for each card, and a split for a lot. Put it in a `Section`.
struct CardCostRows: View {
    var cards: [OwnedCard]
    @Binding var basisTexts: [UUID: String]
    var name: (OwnedCard) -> String

    @State private var splitTotalText = ""

    var body: some View {
        ForEach(cards) { card in
            MoneyField(label: name(card), text: Binding(
                get: { basisTexts[card.id] ?? "" },
                set: { basisTexts[card.id] = $0 }
            ))
        }
        if cards.count > 1 {
            HStack {
                MoneyField(label: "Split a total", text: $splitTotalText)
                Button("Split") { split() }
                    .disabled(Money.cents(from: splitTotalText) == nil)
            }
        }
    }

    private func split() {
        guard let total = Money.cents(from: splitTotalText) else { return }
        for (card, share) in zip(cards, Allocation.splitEqually(total, into: cards.count)) {
            basisTexts[card.id] = Money.fieldText(share)
        }
    }

    /// Fills each card's cost from its record once. A typed figure stays.
    static func seeded(_ cards: [OwnedCard], _ texts: [UUID: String]) -> [UUID: String] {
        var out = texts
        for card in cards where out[card.id] == nil {
            out[card.id] = SaleEditor.knownBasis(card).map(Money.fieldText) ?? ""
        }
        return out
    }

    /// The typed cost of each card, in the order of `cards`. Nil is no cost.
    static func typedCents(_ cards: [OwnedCard], _ texts: [UUID: String]) -> [Int?] {
        cards.map { Money.cents(from: texts[$0.id] ?? "") }
    }
}

/// A gain in green, a loss in red, or "not known".
struct GainText: View {
    var cents: Int?

    var body: some View {
        if let cents {
            Text((cents >= 0 ? "" : "−") + abs(cents).asCurrency)
                .monospacedDigit()
                .foregroundStyle(cents >= 0 ? Color.green : Color.red)
        } else {
            Text("not known").foregroundStyle(.secondary)
        }
    }
}
