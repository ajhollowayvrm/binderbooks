import SwiftData
import SwiftUI

/// Change a purchase: the day, the vendor, the note, and the money.
struct EditPurchaseSheet: View {
    let purchase: Purchase
    var onSaved: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var date: Date
    @State private var vendor: String
    @State private var note: String
    @State private var itemText: String
    @State private var shippingText: String
    @State private var taxText: String
    @State private var feesText: String
    @State private var failed = false

    init(purchase: Purchase, onSaved: @escaping () -> Void) {
        self.purchase = purchase
        self.onSaved = onSaved
        _date = State(initialValue: purchase.date)
        _vendor = State(initialValue: purchase.vendor)
        _note = State(initialValue: purchase.note)
        _itemText = State(initialValue: Money.fieldText(purchase.itemCostCents))
        _shippingText = State(initialValue: Self.text(purchase.shippingCents))
        _taxText = State(initialValue: Self.text(purchase.taxCents))
        _feesText = State(initialValue: Self.text(purchase.feesCents))
    }

    private static func text(_ cents: Int) -> String {
        cents == 0 ? "" : Money.fieldText(cents)
    }

    private var cards: [OwnedCard] { purchase.items.flatMap(\.cards) }

    /// Nil while the item cost does not read as money.
    private var details: PurchaseEditor.Details? {
        guard let item = Money.cents(from: itemText) else { return nil }
        var details = PurchaseEditor.Details(purchase)
        details.date = date
        details.vendor = vendor
        details.note = note
        details.itemCostCents = item
        details.shippingCents = Money.cents(from: shippingText) ?? 0
        details.taxCents = Money.cents(from: taxText) ?? 0
        details.feesCents = Money.cents(from: feesText) ?? 0
        return details
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Bought", selection: $date, displayedComponents: .date)
                    TextField("Vendor, e.g. Gamecraft", text: $vendor)
                        .textInputAutocapitalization(.words)
                    TextField("What it was", text: $note, axis: .vertical)
                } footer: {
                    if !cards.isEmpty {
                        Text("A card that took this purchase's date moves with a new date.")
                    }
                }

                Section {
                    MoneyField(label: "Item cost", text: $itemText)
                    MoneyField(label: "Shipping", text: $shippingText)
                    MoneyField(label: "Tax", text: $taxText)
                    MoneyField(label: "Fees", text: $feesText)
                    LabeledContent("Landed") {
                        Text((details?.landedCostCents ?? 0).asCurrency).font(.body.weight(.semibold).monospacedDigit())
                    }
                } header: {
                    Text("Money")
                } footer: {
                    Text(moneyFooter)
                }
            }
            .navigationTitle("Edit purchase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(details == nil)
                }
            }
            .alert("The purchase did not save", isPresented: $failed) {
                Button("OK") {}
            } message: {
                Text("The store did not accept the change. Try again.")
            }
        }
    }

    private var moneyFooter: String {
        if cards.isEmpty { return "No cards have come out of this purchase yet." }
        if PurchaseEditor.canResplit(purchase) {
            return "A new total splits again over the cards you did not price yourself."
        }
        return "Some cards from this purchase carry a cost from the import, so a new total does not change what any card cost."
    }

    private func save() {
        guard let details else { return }
        do {
            try PurchaseEditor.apply(details, to: purchase, context: modelContext)
            onSaved()
            dismiss()
        } catch {
            failed = true
        }
    }
}
