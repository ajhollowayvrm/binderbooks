import SwiftData
import SwiftUI

/// Add a card to inventory by hand: how many, which printing, what condition,
/// what it cost. The short road for a card that was never scanned.
///
/// With a catalog product, the sheet adds that product. Without one, he types
/// the card himself. That is the road for a Chinese or an Italian print, which
/// TCGplayer does not carry. The card keeps his name, set, number, language,
/// and value, and has no `productId`.
///
/// The cards can join a purchase he already recorded, start a new one, or
/// stand alone. A cost typed here is his price and the purchase total never
/// overwrites it. With no cost, the cards take a share of the purchase they
/// join, the same as a scanned card.
struct AddToInventorySheet: View {
    /// Nil when he enters the card by hand.
    let detail: ProductDetail?
    /// Called after a save, before the sheet dismisses.
    var onAdded: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Purchase.date, order: .reverse) private var purchases: [Purchase]

    enum PurchaseChoice: Hashable {
        case none
        case new
        case existing(UUID)
    }

    /// The printings a hand-entered card can pick from. None is required.
    static let handPrintings = ["Normal", "Holofoil", "Reverse Holofoil"]

    @State private var quantity = 1
    @State private var printing: String
    @State private var condition = CardCondition.nearMint.rawValue
    @State private var costText = ""
    @State private var choice: PurchaseChoice = .none
    @State private var vendor = ""
    @State private var date = Date()
    @State private var choosingPurchase = false

    @State private var manualName: String
    @State private var manualSetName = ""
    @State private var manualNumber = ""
    @State private var valueText = ""
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
    private var costCents: Int? { Money.cents(from: costText) }
    private var valueCents: Int? { Money.cents(from: valueText) }
    private var printings: [String] { detail?.prices.map(\.subTypeName) ?? Self.handPrintings }
    private var trimmedName: String { manualName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cardName: String { detail?.hit.name ?? trimmedName }

    /// Only the quantity is required, and a name for a hand-entered card. A
    /// vendor, a date, a cost, and a value are all optional, because he adds
    /// cards he was given as often as cards he bought.
    private var canSave: Bool {
        guard quantity > 0, costText.isEmpty || costCents != nil else { return false }
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
                    MoneyField(label: quantity > 1 ? "Total cost" : "Cost", text: $costText)
                } footer: {
                    Text(costDescription)
                }

                Section {
                    // A pushed list with search, not a menu: he has more
                    // purchases than a menu can show.
                    Button {
                        choosingPurchase = true
                    } label: {
                        HStack {
                            Text("Purchase").foregroundStyle(.primary)
                            Spacer()
                            Text(choiceTitle)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if case .new = choice {
                        TextField("Vendor, e.g. Walmart — optional", text: $vendor)
                            .textInputAutocapitalization(.words)
                        DatePicker("Bought", selection: $date, displayedComponents: .date)
                    }
                } footer: {
                    Text(purchaseDescription)
                }
            }
            .navigationDestination(isPresented: $choosingPurchase) {
                purchasePicker
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
            Text("For a card the catalog does not carry, such as a Chinese or an Italian print. The value is your figure. The app uses it as the card's market value.")
        }
    }

    private var costDescription: String {
        guard let costCents else { return "Leave it blank for no cost yet." }
        guard quantity > 1 else { return "\(costCents.asCurrency) for this card." }
        let low = Allocation.splitEqually(costCents, into: quantity).min() ?? 0
        return "\(costCents.asCurrency) over \(quantity) cards is \(low.asCurrency) each."
    }

    private var purchaseDescription: String {
        switch choice {
        case .none: return "The cards stand alone, with only the cost typed above."
        case .new: return "A purchase for this cost is added to the ledger."
        case .existing: return costCents == nil
            ? "The cards take a share of that purchase's total."
            : "The cost typed above is theirs; the purchase total covers the rest."
        }
    }

    private var choiceTitle: String {
        switch choice {
        case .none: return "None"
        case .new: return "New purchase"
        case .existing(let id):
            return purchases.first { $0.id == id }.map(purchaseTitle) ?? "None"
        }
    }

    private var purchasePicker: some View {
        PurchasePickerList(
            around: Date(),
            footer: purchaseDescription,
            isCurrent: { choice == .existing($0.id) },
            leading: {
                choiceRow("None", selected: choice == .none) { choice = .none }
                choiceRow("New purchase", selected: choice == .new) { choice = .new }
            },
            onPick: { pick(.existing($0.id)) }
        )
        .navigationTitle("Purchase")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choiceRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            choosingPurchase = false
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pick(_ picked: PurchaseChoice) {
        choice = picked
        choosingPurchase = false
    }

    private func purchaseTitle(_ purchase: Purchase) -> String {
        let vendor = purchase.vendor.isEmpty ? "Purchase" : purchase.vendor
        return "\(vendor) · \(purchase.date.formatted(date: .abbreviated, time: .omitted)) · \(purchase.landedCostCents.asCurrency)"
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
        let productId = detail?.hit.productId ?? 0
        let isSealed = detail?.hit.isSealed ?? false
        let cards = (0..<quantity).map { _ -> OwnedCard in
            let card = OwnedCard(productId: productId, printing: printing, condition: condition, confidence: .manual)
            card.isSealedSelf = isSealed
            if isHandEntry {
                card.manualName = trimmedName
                card.manualSetName = manualSetName.trimmingCharacters(in: .whitespacesAndNewlines)
                card.manualNumber = manualNumber.trimmingCharacters(in: .whitespacesAndNewlines)
                card.manualMarketCents = valueCents
                card.language = language
            }
            return card
        }
        if let costCents {
            let shares = Allocation.splitEqually(costCents, into: cards.count)
            for (card, share) in zip(cards, shares) {
                card.acquisitionBasisCents = share
                card.basisIsManual = true
            }
        }

        let purchase: Purchase?
        switch choice {
        case .none:
            purchase = nil
        case .new:
            let created = Purchase(date: date, vendor: vendor.trimmingCharacters(in: .whitespaces), note: cardName, itemCostCents: costCents ?? 0)
            modelContext.insert(created)
            purchase = created
        case .existing(let id):
            purchase = purchases.first { $0.id == id }
        }

        if let purchase {
            let item = PurchaseItem(productId: productId, quantity: cards.count, isSealed: isSealed)
            item.purchase = purchase
            modelContext.insert(item)
            for card in cards {
                card.acquiredAt = purchase.date
                card.sourceItem = item
                modelContext.insert(card)
            }
            Allocation.allocate(purchase)
            Allocation.writeCardBases(purchase)
        } else {
            for card in cards { modelContext.insert(card) }
        }
        try? modelContext.save()
        onAdded?()
        dismiss()
    }
}
