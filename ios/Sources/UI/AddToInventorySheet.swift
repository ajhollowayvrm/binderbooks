import SwiftData
import SwiftUI

/// Add a catalog product to inventory by hand: how many, which printing, what
/// condition, what it cost. The short road for a card that was never scanned.
///
/// The cards can join a purchase he already recorded, start a new one, or
/// stand alone. A cost typed here is his price and the purchase total never
/// overwrites it. With no cost, the cards take a share of the purchase they
/// join, the same as a scanned card.
struct AddToInventorySheet: View {
    let detail: ProductDetail

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Purchase.date, order: .reverse) private var purchases: [Purchase]

    enum PurchaseChoice: Hashable {
        case none
        case new
        case existing(UUID)
    }

    @State private var quantity = 1
    @State private var printing: String
    @State private var condition = CardCondition.nearMint.rawValue
    @State private var costText = ""
    @State private var choice: PurchaseChoice = .none
    @State private var vendor = ""
    @State private var date = Date()

    init(detail: ProductDetail) {
        self.detail = detail
        _printing = State(initialValue: detail.prices.first?.subTypeName ?? "")
    }

    private var costCents: Int? { Money.cents(from: costText) }
    private var printings: [String] { detail.prices.map(\.subTypeName) }

    private var canSave: Bool {
        if case .new = choice, vendor.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return quantity > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Quantity: \(quantity)", value: $quantity, in: 1...99)
                    if printings.count > 1 {
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
                    Picker("Purchase", selection: $choice) {
                        Text("None").tag(PurchaseChoice.none)
                        Text("New purchase").tag(PurchaseChoice.new)
                        ForEach(purchases.prefix(20)) { purchase in
                            Text(purchaseTitle(purchase)).tag(PurchaseChoice.existing(purchase.id))
                        }
                    }
                    if case .new = choice {
                        TextField("Vendor, e.g. Walmart", text: $vendor)
                            .textInputAutocapitalization(.words)
                        DatePicker("Bought", selection: $date, displayedComponents: .date)
                    }
                } footer: {
                    Text(purchaseDescription)
                }
            }
            .navigationTitle(detail.hit.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }.disabled(!canSave)
                }
            }
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
        let cards = (0..<quantity).map { _ in
            OwnedCard(productId: detail.hit.productId, printing: printing, condition: condition, confidence: .manual)
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
            let created = Purchase(date: date, vendor: vendor.trimmingCharacters(in: .whitespaces), note: detail.hit.name, itemCostCents: costCents ?? 0)
            modelContext.insert(created)
            purchase = created
        case .existing(let id):
            purchase = purchases.first { $0.id == id }
        }

        if let purchase {
            let item = PurchaseItem(productId: detail.hit.productId, quantity: cards.count, isSealed: detail.hit.isSealed)
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
        dismiss()
    }
}
