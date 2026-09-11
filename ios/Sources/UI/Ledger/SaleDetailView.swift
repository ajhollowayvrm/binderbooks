import SwiftData
import SwiftUI

/// One order: what it paid, what came off it, and which cards left.
struct SaleDetailView: View {
    let saleID: UUID

    @Environment(InventoryModel.self) private var inventory
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var sales: [Sale]
    @State private var confirmDelete = false
    @State private var blockedMessage: String?

    init(saleID: UUID) {
        self.saleID = saleID
        _sales = Query(filter: #Predicate<Sale> { $0.id == saleID })
    }

    private var sale: Sale? { sales.first }

    var body: some View {
        List {
            if let sale {
                Section {
                    LabeledContent("Sold", value: sale.soldAt.formatted(date: .abbreviated, time: .omitted))
                    LabeledContent("Channel", value: LedgerEntry.channelName(sale.channelRaw))
                    if !sale.externalOrderId.isEmpty {
                        LabeledContent("Order", value: sale.externalOrderId)
                    }
                }

                Section("Money") {
                    LabeledContent("Gross", value: sale.grossCents.asCurrency)
                    if sale.shippingChargedCents > 0 {
                        LabeledContent("Shipping charged", value: sale.shippingChargedCents.asCurrency)
                    }
                    deduction("Fees", sale.marketplaceFeesCents)
                    deduction("Sales tax", sale.salesTaxCents)
                    deduction("Shipping", sale.shippingCostCents)
                    deduction("Other fees", sale.otherFeesCents)
                    LabeledContent("Net") {
                        Text(sale.netCents.asCurrency).font(.body.weight(.semibold).monospacedDigit())
                    }
                }

                gain(for: sale)

                Section {
                    if sale.lines.isEmpty {
                        Text("This order recorded a price and no cards.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sale.lines.sorted { $0.describedAs < $1.describedAs }) { line in
                        row(for: line)
                            .swipeActions(edge: .trailing) {
                                if line.card != nil {
                                    Button("Unsell", role: .destructive) { unsell(line) }
                                }
                            }
                    }
                } header: {
                    Text(sale.lines.count == 1 ? "1 card" : "\(sale.lines.count) cards")
                } footer: {
                    if sale.lines.contains(where: \.basisIncomplete) {
                        Text("A card with no cost is not counted in the gain. The revenue is real; what it cost was never recorded.")
                    } else if sale.lines.contains(where: { $0.card != nil }) {
                        Text("Swipe a card to put it back in inventory.")
                    }
                }

                Section {
                    Button("Delete order", role: .destructive) { requestDelete(sale) }
                }
            } else {
                ContentUnavailableView("This order is gone", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle("Order")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this order?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteSale() }
        }
        .alert("Cards are still on this order", isPresented: Binding(get: { blockedMessage != nil }, set: { if !$0 { blockedMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(blockedMessage ?? "")
        }
    }

    /// The line goes and the card is his again. The order keeps its money.
    private func unsell(_ line: SaleLine) {
        if let card = line.card {
            CardTagEditor(context: modelContext).remove(ReservedTag.sold, from: [card])
        }
        modelContext.delete(line)
        try? modelContext.save()
    }

    /// Blocked while a card in inventory points here. Deleting the order would
    /// leave the card tagged sold with nothing to say what sold it.
    private func requestDelete(_ sale: Sale) {
        let linked = sale.lines.filter { $0.card != nil }.count
        if linked > 0 {
            blockedMessage = linked == 1
                ? "1 card in inventory is on this order. Unsell it first."
                : "\(linked) cards in inventory are on this order. Unsell them first."
        } else {
            confirmDelete = true
        }
    }

    private func deleteSale() {
        guard let sale else { return }
        modelContext.delete(sale)
        try? modelContext.save()
        dismiss()
    }

    @ViewBuilder private func deduction(_ label: String, _ cents: Int) -> some View {
        if cents != 0 {
            LabeledContent(label) { Text("−" + cents.asCurrency) }
        }
    }

    @ViewBuilder private func gain(for sale: Sale) -> some View {
        Section {
            if let gain = sale.realizedGainCents {
                LabeledContent("Gain") {
                    Text(gain >= 0 ? gain.asCurrency : "−" + (-gain).asCurrency)
                        .foregroundStyle(gain >= 0 ? Color.green : Color.red)
                }
            } else {
                LabeledContent("Gain", value: "not known")
            }
        } footer: {
            if sale.realizedGainCents == nil {
                Text("The gain needs a cost on every card. This order has at least one card with none.")
            }
        }
    }

    @ViewBuilder private func row(for line: SaleLine) -> some View {
        let name = line.card.flatMap { inventory.hits[$0.productId]?.name } ?? line.describedAs
        if let card = line.card {
            NavigationLink(value: AppRoute.ownedCard(card.id)) {
                lineBody(name: name, line: line)
            }
        } else {
            lineBody(name: name, line: line)
        }
    }

    private func lineBody(name: String, line: SaleLine) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name.isEmpty ? "Unnamed card" : name)
                if line.card == nil {
                    Text("not linked to a card in inventory")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(line.basisIncomplete ? "no cost" : line.basisCents.asCurrency)
                .font(.callout.monospacedDigit())
                .foregroundStyle(line.basisIncomplete ? .secondary : .primary)
        }
    }
}
