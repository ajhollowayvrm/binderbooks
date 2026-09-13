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
    @State private var editing = false
    @State private var attachTarget: AttachTarget?
    @State private var costTarget: SaleLine?
    @State private var costText = ""
    @State private var showingCost = false

    /// What the attach sheet opens for: new cards, or one card for a line
    /// that links none.
    private struct AttachTarget: Identifiable {
        let id = UUID()
        var line: SaleLine?
    }

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

                Section {
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
                } header: {
                    Text("Money")
                } footer: {
                    if sale.costsEstimated {
                        Text("The fees and the postage are estimates. The order file had no fees, so the app estimated them from your other orders on this channel.")
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
                            .swipeActions(edge: .leading) {
                                Button("Cost") { editCost(line) }
                                    .tint(.blue)
                            }
                            .swipeActions(edge: .trailing) {
                                if line.card != nil {
                                    Button("Unsell", role: .destructive) { unsell(line) }
                                } else {
                                    Button("Link") { attachTarget = AttachTarget(line: line) }
                                        .tint(.accentColor)
                                }
                            }
                    }
                    Button {
                        attachTarget = AttachTarget()
                    } label: {
                        Label("Attach cards", systemImage: "plus")
                    }
                } header: {
                    Text(sale.lines.count == 1 ? "1 card" : "\(sale.lines.count) cards")
                } footer: {
                    linesFooter(sale)
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
        .toolbar {
            if sale != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }
                }
            }
        }
        .sheet(isPresented: $editing) {
            if let sale {
                EditSaleSheet(sale: sale)
            }
        }
        .sheet(item: $attachTarget) { target in
            if let sale {
                AttachCardsSheet(sale: sale, line: target.line) { inventory.invalidateHaystacks() }
            }
        }
        // `presenting` hands the line to the button, so the save does not
        // depend on when the alert clears its state.
        .alert("What the card cost", isPresented: $showingCost, presenting: costTarget) { line in
            TextField("0.00", text: $costText)
                .keyboardType(.decimalPad)
            Button("Save") { saveCost(line) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("What you paid for this card. Leave it blank when the cost is not known.")
        }
        .confirmationDialog("Delete this order?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteSale() }
        }
        .alert("Cards are still on this order", isPresented: Binding(get: { blockedMessage != nil }, set: { if !$0 { blockedMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(blockedMessage ?? "")
        }
    }

    @ViewBuilder private func linesFooter(_ sale: Sale) -> some View {
        let notes = [
            sale.lines.contains(where: \.basisIncomplete)
                ? "A card with no cost is not counted in the gain. The revenue is real; what it cost was never recorded." : nil,
            sale.lines.isEmpty ? nil : "Swipe a line to the right to change its cost.",
            sale.lines.contains(where: { $0.card == nil })
                ? "Swipe a line that links no card to the left to link one from inventory." : nil,
            sale.lines.contains(where: { $0.card != nil })
                ? "Swipe a card to the left to put it back in inventory." : nil,
        ].compactMap { $0 }
        if !notes.isEmpty {
            Text(notes.joined(separator: " "))
        }
    }

    private func editCost(_ line: SaleLine) {
        costText = line.basisIncomplete ? "" : Money.fieldText(line.basisCents)
        costTarget = line
        showingCost = true
    }

    /// A blank field is no cost. Text that does not read as money changes
    /// nothing, so a typo does not wipe a cost.
    private func saveCost(_ line: SaleLine) {
        let typed = costText.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty {
            try? SaleEditor.setCost(nil, on: line, context: modelContext)
        } else if let cents = Money.cents(from: typed) {
            try? SaleEditor.setCost(cents, on: line, context: modelContext)
        }
    }

    /// The line goes and the card is his again. The order keeps its money.
    private func unsell(_ line: SaleLine) {
        if let card = line.card {
            CardTagEditor(context: modelContext).remove(ReservedTag.sold, from: [card])
        }
        modelContext.delete(line)
        try? modelContext.save()
        inventory.invalidateHaystacks()
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
                Text(sale.lines.isEmpty
                     ? "The gain needs the cards on the order and a cost on each. Attach the cards that sold."
                     : "The gain needs a cost on every card. This order has at least one card with none.")
            }
        }
    }

    @ViewBuilder private func row(for line: SaleLine) -> some View {
        let name = line.card.flatMap { inventory.hits[$0.productId]?.name ?? ($0.manualName.isEmpty ? nil : $0.manualName) } ?? line.describedAs
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
