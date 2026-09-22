import SwiftData
import SwiftUI

/// Sell cards out of inventory. One order holds the money, one line per card
/// says which cards left. The cards are tagged "sold" and leave the page.
struct SellSheet: View {
    var cards: [OwnedCard]
    var name: (OwnedCard) -> String
    var onSold: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var channel = "TCGplayer"
    @State private var soldAt = Date()
    @State private var orderId = ""
    @State private var grossText = ""
    @State private var feesText = ""
    @State private var shippingChargedText = ""
    @State private var shippingCostText = ""
    @State private var taxText = ""

    private var grossCents: Int? { Money.cents(from: grossText) }
    private var canSave: Bool {
        guard let grossCents, grossCents > 0 else { return false }
        return !channel.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var netCents: Int {
        (grossCents ?? 0) + (Money.cents(from: shippingChargedText) ?? 0)
            - (Money.cents(from: feesText) ?? 0) - (Money.cents(from: taxText) ?? 0)
            - (Money.cents(from: shippingCostText) ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Sold", selection: $soldAt, displayedComponents: .date)
                    TextField("Channel, e.g. TCGplayer", text: $channel)
                        .textInputAutocapitalization(.words)
                    TextField("Order number", text: $orderId)
                    MoneyField(label: "Gross", text: $grossText)
                }

                Section("What came off it") {
                    MoneyField(label: "Fees", text: $feesText)
                    MoneyField(label: "Sales tax", text: $taxText)
                    MoneyField(label: "Shipping paid", text: $shippingCostText)
                    MoneyField(label: "Shipping charged", text: $shippingChargedText)
                }

                Section {
                    LabeledContent("Net") {
                        Text(netCents.asCurrency).font(.body.weight(.semibold).monospacedDigit())
                    }
                }
            }
            .navigationTitle(cards.count == 1 ? "Sell 1 card" : "Sell \(cards.count) cards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sell") { save() }.disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        guard let grossCents else { return }
        let sale = Sale(soldAt: soldAt, channelRaw: AddTransactionSheet.channelKey(channel), grossCents: grossCents)
        sale.marketplaceFeesCents = Money.cents(from: feesText) ?? 0
        sale.salesTaxCents = Money.cents(from: taxText) ?? 0
        sale.shippingCostCents = Money.cents(from: shippingCostText) ?? 0
        sale.shippingChargedCents = Money.cents(from: shippingChargedText) ?? 0
        sale.externalOrderId = orderId.trimmingCharacters(in: .whitespaces)
        modelContext.insert(sale)

        for card in cards {
            let line = SaleLine(sale: sale, card: card)
            line.describedAs = name(card)
            modelContext.insert(line)
        }
        CardTagEditor(context: modelContext).add(ReservedTag.sold, to: cards)
        try? modelContext.save()
        onSold()
        dismiss()
    }
}
