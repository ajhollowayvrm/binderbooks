import SwiftData
import SwiftUI

/// Sell cards out of inventory. One order holds the money, one line per card
/// holds what that card cost. The cards are tagged "sold" and leave the page.
///
/// The cost is what he paid for the card, not a share of the price. It fills
/// from the card's basis where one is known. For a lot with no per-card
/// figure he types one total and it splits evenly, the same way he prices a
/// batch at review.
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
    @State private var basisTexts: [UUID: String]
    @State private var splitTotalText = ""

    init(cards: [OwnedCard], name: @escaping (OwnedCard) -> String, onSold: @escaping () -> Void) {
        self.cards = cards
        self.name = name
        self.onSold = onSold
        var texts: [UUID: String] = [:]
        for card in cards where card.totalBasisCents > 0 {
            texts[card.id] = Money.fieldText(card.totalBasisCents)
        }
        _basisTexts = State(initialValue: texts)
    }

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

    private var basisCents: [Int?] { cards.map { Money.cents(from: basisTexts[$0.id] ?? "") } }
    private var allBasisKnown: Bool { basisCents.allSatisfy { $0 != nil } }
    private var gainCents: Int? {
        guard allBasisKnown else { return nil }
        return netCents - basisCents.compactMap { $0 }.reduce(0, +)
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
                } header: {
                    Text("What the cards cost")
                } footer: {
                    Text("What you paid for each card. A card left blank has no cost, and the order's gain is not known until it does.")
                }

                Section {
                    LabeledContent("Net") {
                        Text(netCents.asCurrency).font(.body.weight(.semibold).monospacedDigit())
                    }
                    LabeledContent("Gain") {
                        if let gain = gainCents {
                            Text((gain >= 0 ? "" : "−") + abs(gain).asCurrency)
                                .monospacedDigit()
                                .foregroundStyle(gain >= 0 ? Color.green : Color.red)
                        } else {
                            Text("not known").foregroundStyle(.secondary)
                        }
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

    private func split() {
        guard let total = Money.cents(from: splitTotalText) else { return }
        let shares = Allocation.splitEqually(total, into: cards.count)
        for (card, share) in zip(cards, shares) {
            basisTexts[card.id] = Money.fieldText(share)
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

        for (card, cents) in zip(cards, basisCents) {
            let line = SaleLine(sale: sale, card: card, basisCents: cents ?? 0, basisIncomplete: cents == nil)
            line.describedAs = name(card)
            modelContext.insert(line)
        }
        CardTagEditor(context: modelContext).add(ReservedTag.sold, to: cards)
        try? modelContext.save()
        onSold()
        dismiss()
    }
}
