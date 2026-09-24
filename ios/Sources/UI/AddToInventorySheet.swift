import SwiftData
import SwiftUI

/// Add a card to inventory by hand: how many, which printing, what condition.
/// No purchase and no cost. The short road for a card that was never scanned.
///
/// With a catalog product, the sheet adds that product. Without one, he types
/// the card himself. That is the road for an Italian or a Korean print, which
/// TCGplayer does not carry. The card keeps his name, set, number, language,
/// and value, and has no `productId`.
struct AddToInventorySheet: View {
    /// Nil when he enters the card by hand.
    let detail: ProductDetail?
    /// Called after a save, before the sheet dismisses.
    var onAdded: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// The printings a hand-entered card can pick from. None is required.
    static let handPrintings = ["Normal", "Holofoil", "Reverse Holofoil"]

    @State private var quantity = 1
    @State private var printing: String
    @State private var condition = CardCondition.nearMint.rawValue

    @State private var manualName: String
    @State private var manualSetName = ""
    @State private var manualNumber = ""
    @State private var valueText = ""
    /// A preorder, or an order in the mail. See `OnOrder`.
    @State private var onOrder = false
    @State private var hasExpected = false
    @State private var expected = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    /// Kept between entries, because he enters a stack of Italian cards one
    /// after another.
    @AppStorage("handEntryLanguage") private var language = "en"

    init(detail: ProductDetail, onAdded: (() -> Void)? = nil) {
        self.detail = detail
        self.onAdded = onAdded
        _printing = State(initialValue: detail.prices.first?.subTypeName ?? "")
        _manualName = State(initialValue: "")
    }

    /// A card the catalog does not carry. `name` fills the name field, because
    /// the search text he typed is usually the card's name.
    init(handEnteredName name: String, onAdded: (() -> Void)? = nil) {
        self.detail = nil
        self.onAdded = onAdded
        _printing = State(initialValue: "")
        _manualName = State(initialValue: name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var isHandEntry: Bool { detail == nil }
    private var valueCents: Int? { Money.cents(from: valueText) }
    private var printings: [String] { detail?.prices.map(\.subTypeName) ?? Self.handPrintings }
    private var trimmedName: String { manualName.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Only the quantity is required, and a name for a hand-entered card. A
    /// value is optional.
    private var canSave: Bool {
        guard quantity > 0 else { return false }
        guard isHandEntry else { return true }
        return !trimmedName.isEmpty && (valueText.isEmpty || valueCents != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                if isHandEntry {
                    handEntrySection
                }

                Section {
                    Stepper("Quantity: \(quantity)", value: $quantity, in: 1...99)
                    if isHandEntry {
                        // A second tap on the chosen printing clears it.
                        chipRow("Printing (optional)", printings, selected: printing) { printing = printing == $0 ? "" : $0 }
                    } else if printings.count > 1 {
                        chipRow("Printing", printings, selected: printing) { printing = $0 }
                    }
                    chipRow("Condition", CardCondition.allCases.map(\.rawValue), selected: condition) { condition = $0 }
                }

                Section {
                    Toggle("Not here yet", isOn: $onOrder.animation())
                    if onOrder {
                        Toggle("Expected date", isOn: $hasExpected.animation())
                        if hasExpected {
                            DatePicker("Arrives", selection: $expected, displayedComponents: .date)
                        }
                    }
                } footer: {
                    if onOrder {
                        Text("It counts in inventory once you mark it received, and it cannot be ripped or listed until then.")
                    }
                }
            }
            .navigationTitle(detail?.hit.name ?? "Add by hand")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }.disabled(!canSave)
                }
            }
        }
    }

    private var handEntrySection: some View {
        Section {
            TextField("Name", text: $manualName)
                .textInputAutocapitalization(.words)
            TextField("Set (optional)", text: $manualSetName)
                .textInputAutocapitalization(.words)
            TextField("Number, e.g. 025/165 (optional)", text: $manualNumber)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Picker("Language", selection: $language) {
                ForEach(CardLanguage.codes, id: \.self) { code in
                    Text(CardLanguage.name(code)).tag(code)
                }
            }
            MoneyField(label: "Value each", text: $valueText)
        } header: {
            Text("The card")
        } footer: {
            Text("For a card the catalog does not carry, such as an Italian or a Korean print. The value is your figure. The app uses it as the card's market value.")
        }
    }

    private func chipRow(_ label: String, _ options: [String], selected: String, onPick: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(options, id: \.self) { option in
                        Chip(title: option, isSelected: option == selected) { onPick(option) }
                    }
                }
            }
        }
    }

    private func save() {
        let added = CardEditor.addCards(
            productId: detail?.hit.productId ?? 0,
            isSealed: detail?.hit.isSealed ?? false,
            quantity: quantity,
            printing: printing,
            condition: condition,
            manualName: isHandEntry ? trimmedName : "",
            manualSetName: isHandEntry ? manualSetName : "",
            manualNumber: isHandEntry ? manualNumber : "",
            manualMarketCents: isHandEntry ? valueCents : nil,
            language: isHandEntry ? language : "en",
            context: modelContext
        )
        if onOrder {
            OnOrder.mark(added, expected: hasExpected ? expected : nil, context: modelContext)
        }
        onAdded?()
        dismiss()
    }
}
