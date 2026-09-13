import SwiftData
import SwiftUI

/// Change an order that is on the books: the day, the channel, the order
/// number, and the money. The cards do not change here. The order screen
/// attaches and unsells them.
struct EditSaleSheet: View {
    let sale: Sale

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var soldAt: Date
    @State private var channel: String
    @State private var orderId: String
    @State private var grossText: String
    @State private var feesText: String
    @State private var taxText: String
    @State private var shippingCostText: String
    @State private var shippingChargedText: String
    @State private var otherFeesText: String
    @State private var estimated: Bool
    @State private var failed = false

    init(sale: Sale) {
        self.sale = sale
        _soldAt = State(initialValue: sale.soldAt)
        _channel = State(initialValue: LedgerEntry.channelName(sale.channelRaw))
        _orderId = State(initialValue: sale.externalOrderId)
        _grossText = State(initialValue: Money.fieldText(sale.grossCents))
        _feesText = State(initialValue: Self.text(sale.marketplaceFeesCents))
        _taxText = State(initialValue: Self.text(sale.salesTaxCents))
        _shippingCostText = State(initialValue: Self.text(sale.shippingCostCents))
        _shippingChargedText = State(initialValue: Self.text(sale.shippingChargedCents))
        _otherFeesText = State(initialValue: Self.text(sale.otherFeesCents))
        _estimated = State(initialValue: sale.costsEstimated)
    }

    /// An empty field for a zero, so a typed figure does not start after "0.00".
    private static func text(_ cents: Int) -> String {
        cents == 0 ? "" : Money.fieldText(cents)
    }

    /// Nil while the gross does not read as money or the channel is empty.
    private var details: SaleEditor.Details? {
        guard let gross = Money.cents(from: grossText) else { return nil }
        let name = channel.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        var details = SaleEditor.Details(sale)
        details.soldAt = soldAt
        details.channelRaw = AddTransactionSheet.channelKey(name)
        details.externalOrderId = orderId
        details.grossCents = gross
        details.marketplaceFeesCents = Money.cents(from: feesText) ?? 0
        details.salesTaxCents = Money.cents(from: taxText) ?? 0
        details.shippingCostCents = Money.cents(from: shippingCostText) ?? 0
        details.shippingChargedCents = Money.cents(from: shippingChargedText) ?? 0
        details.otherFeesCents = Money.cents(from: otherFeesText) ?? 0
        details.costsEstimated = estimated
        return details
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
                    MoneyField(label: "Other fees", text: $otherFeesText)
                }

                if sale.costsEstimated {
                    Section {
                        Toggle("Fees and postage are estimates", isOn: $estimated)
                    } footer: {
                        Text("Turn this off when the fees and the postage are what the marketplace charged. A change to either figure turns it off.")
                    }
                }

                Section {
                    LabeledContent("Net") {
                        Text((details?.netCents ?? 0).asCurrency)
                            .font(.body.weight(.semibold).monospacedDigit())
                    }
                }
            }
            .navigationTitle("Edit order")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: feesText) { estimated = false }
            .onChange(of: shippingCostText) { estimated = false }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(details == nil)
                }
            }
            .alert("The order did not save", isPresented: $failed) {
                Button("OK") {}
            } message: {
                Text("The store did not accept the change. Try again.")
            }
        }
    }

    private func save() {
        guard let details else { return }
        do {
            try SaleEditor.apply(details, to: sale, context: modelContext)
            dismiss()
        } catch {
            failed = true
        }
    }
}
