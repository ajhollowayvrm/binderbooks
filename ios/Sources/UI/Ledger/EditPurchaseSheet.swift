import SwiftData
import SwiftUI

/// Change a purchase: the day, the vendor, the note, the money, and what was
/// in it.
///
/// What was in it comes from two places: the whole catalog, for a product he
/// does not hold yet, and his own inventory, for a card he already holds.
/// Nothing changes until Save, so Cancel undoes both.
struct EditPurchaseSheet: View {
    let purchase: Purchase
    var onSaved: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var purchases: [Purchase]
    @Environment(InventoryModel.self) private var inventory

    @State private var date: Date
    @State private var vendor: String
    @State private var note: String
    @State private var itemText: String
    @State private var shippingText: String
    @State private var taxText: String
    @State private var feesText: String
    @State private var failed = false
    @State private var saving = false
    /// New products from the catalog. Save puts them into inventory.
    @State private var lines: [PurchaseIntake.Line] = []
    /// Cards he already holds. Save moves them onto this purchase.
    @State private var heldCards: [OwnedCard] = []
    @State private var searchingCatalog = false
    @State private var pickingHeld = false

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
                    CounterpartyField(title: "Vendor", placeholder: "Vendor, e.g. Gamecraft", text: $vendor, options: Counterparties.names(purchases.map(\.vendor)))
                    TextField("What it was", text: $note, axis: .vertical)
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

                contentsSection
            }
            .task {
                // The split reads market prices.
                await inventory.load(for: purchase.items.flatMap(\.cards))
            }
            .sheet(isPresented: $searchingCatalog) {
                PurchaseCatalogSheet(lines: $lines)
            }
            .sheet(isPresented: $pickingHeld) {
                PickCardsSheet(
                    initial: heldCards.map(\.id),
                    title: "From my inventory",
                    footer: "Sold cards are not on this list. A card on another purchase moves to this one."
                ) { heldCards = $0 }
            }
            .navigationTitle("Edit purchase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(details == nil || saving)
                }
            }
            .alert("The purchase did not save", isPresented: $failed) {
                Button("OK") {}
            } message: {
                Text("The store did not accept the change. Try again.")
            }
        }
    }

    private var contentsSection: some View {
        Section {
            ForEach($lines) { $line in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.name).lineLimit(2)
                        Text(line.isSealed ? "New · Sealed · \(line.setName)" : "New · \(line.setName)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text("\(line.quantity)x").monospacedDigit()
                    Stepper("Quantity", value: $line.quantity, in: 1...999).labelsHidden()
                }
            }
            .onDelete { lines.remove(atOffsets: $0) }
            ForEach(heldCards) { card in
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.displayName(inventory.hits[card.productId]) ?? "Card").lineLimit(2)
                    Text(card.sourceItem?.purchase == nil ? "From inventory" : "From inventory · moves from another purchase")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onDelete { heldCards.remove(atOffsets: $0) }
            Menu {
                Button { searchingCatalog = true } label: {
                    Label("Search the catalog", systemImage: "magnifyingglass")
                }
                Button { pickingHeld = true } label: {
                    Label("Search my inventory", systemImage: "rectangle.stack")
                }
            } label: {
                Label("Add items", systemImage: "plus")
            }
        } header: {
            Text("What was in it")
        } footer: {
            Text("The catalog adds a new product to inventory. Your inventory moves a card you already hold onto this purchase. Nothing changes until you save.")
        }
    }

    private var moneyFooter: String {
        "The total counts in your profit and loss. It splits again over the cards on the purchase, by market price. A cost you typed on a card stays."
    }

    /// The money first, then the new products, then the held cards. Each
    /// step splits the total again, so the last split sees every card.
    private func save() async {
        guard let details else { return }
        saving = true
        defer { saving = false }
        let others = heldCards.compactMap { $0.sourceItem?.purchase }
        await inventory.load(for: ([purchase] + others).flatMap { $0.items.flatMap(\.cards) } + heldCards)
        await inventory.load(productIds: lines.map(\.productId))
        let market: (OwnedCard) -> Int? = { inventory.marketCents(for: $0) }
        do {
            try PurchaseEditor.apply(details, to: purchase, marketCents: market, context: modelContext)
            if !lines.isEmpty {
                PurchaseIntake.record(lines, on: purchase, marketCents: market, context: modelContext)
                try modelContext.save()
            }
            if !heldCards.isEmpty {
                try PurchaseLink.link(heldCards, to: purchase, marketCents: market, context: modelContext)
            }
            inventory.invalidateHaystacks()
            onSaved()
            dismiss()
        } catch {
            failed = true
        }
    }
}
