import SwiftData
import SwiftUI

/// Record money by hand: a purchase, an order, a grading charge, or an expense.
///
/// This writes the money. A purchase can also take what came in it, found in
/// the catalog: each product goes into inventory with its share of the total.
/// A note alone is enough, for a purchase the catalog does not describe.
/// An order can also take the cards that sold, picked
/// from inventory: each card goes on the order with its cost and is tagged
/// sold. An order with no cards reads "gain not known" — the same shape as the
/// 35 imported orders that recorded a price and no lines.
struct AddTransactionSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case purchase = "Purchase"
        case sale = "Order"
        case grading = "Grading"
        case expense = "Expense"

        var id: String { rawValue }
        var isMoneyIn: Bool { self == .sale }
        /// An expense is one amount. Nothing rides on top of it and nothing
        /// comes off it, so the three extra fields would only be empty rows.
        var hasExtras: Bool { self != .expense }
    }

    var onAdded: (LedgerEntry.Kind) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(InventoryModel.self) private var inventory

    @State private var kind: Kind = .purchase
    @State private var date = Date()
    @State private var who = ""
    @State private var category = ""
    @State private var note = ""
    @State private var amountText = ""
    @State private var feesText = ""
    @State private var shippingText = ""
    @State private var taxText = ""
    @State private var saleCards: [OwnedCard] = []
    @State private var basisTexts: [UUID: String] = [:]
    @State private var picking = false
    @State private var lines: [PurchaseIntake.Line] = []
    @State private var searchingCatalog = false

    private var amountCents: Int? { Money.cents(from: amountText) }
    private var feesCents: Int { Money.cents(from: feesText) ?? 0 }
    private var shippingCents: Int { Money.cents(from: shippingText) ?? 0 }
    private var taxCents: Int { Money.cents(from: taxText) ?? 0 }

    private var canSave: Bool {
        guard let amountCents, amountCents > 0 else { return false }
        return !who.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What the row will read in the ledger, before he saves it.
    private var previewCents: Int {
        guard let amountCents else { return 0 }
        switch kind {
        case .purchase: return amountCents + shippingCents + taxCents + feesCents
        case .grading: return amountCents + shippingCents
        case .sale: return amountCents - feesCents - shippingCents - taxCents
        case .expense: return amountCents
        }
    }

    /// Nil until every card has a cost, the same rule as `Sale.realizedGainCents`.
    private var saleGainCents: Int? {
        let typed = CardCostRows.typedCents(saleCards, basisTexts)
        guard !saleCards.isEmpty, typed.allSatisfy({ $0 != nil }) else { return nil }
        return previewCents - typed.compactMap { $0 }.reduce(0, +)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField(whoLabel, text: $who)
                        .textInputAutocapitalization(.words)
                    money(amountLabel, $amountText)
                }

                if kind.hasExtras {
                    Section(extrasLabel) {
                        money("Fees", $feesText)
                        money(kind == .grading ? "Shipping both ways" : "Shipping", $shippingText)
                        if kind != .grading { money("Sales tax", $taxText) }
                    }
                }

                if kind == .sale {
                    Section {
                        CardCostRows(cards: saleCards, basisTexts: $basisTexts, name: cardName)
                        Button {
                            picking = true
                        } label: {
                            Label(saleCards.isEmpty ? "Attach cards" : "Change cards", systemImage: "plus")
                        }
                    } header: {
                        Text(saleCards.isEmpty ? "Cards" : "What the cards cost")
                    } footer: {
                        Text(saleCards.isEmpty
                             ? "Pick the cards that sold, from inventory."
                             : "What you paid for each card. A card left blank has no cost, and the order's gain is not known until it does.")
                    }
                }

                if kind == .expense {
                    Section {
                        // Free text, not a picker. A fixed category list is the
                        // reporting dimension decision 23 rules out.
                        TextField("Category, e.g. Supplies", text: $category)
                            .textInputAutocapitalization(.words)
                    } footer: {
                        Text("For your own bookkeeping. Nothing is broken down by it.")
                    }
                }

                if kind == .purchase {
                    Section {
                        ForEach($lines) { $line in
                            PurchaseLineRow(line: $line)
                        }
                        .onDelete { lines.remove(atOffsets: $0) }
                        Button {
                            searchingCatalog = true
                        } label: {
                            Label(lines.isEmpty ? "Search the catalog" : "Add more", systemImage: "magnifyingglass")
                        }
                    } header: {
                        Text("What was in it")
                    } footer: {
                        Text(lines.isEmpty
                             ? "Find the sealed product or the cards. Each one goes into inventory with its share of the total."
                             : "Each one goes into inventory with its share of the total. Swipe a row to take it off.")
                    }
                }

                if kind == .purchase || kind == .expense {
                    Section {
                        TextField("What it was", text: $note, axis: .vertical)
                    } footer: {
                        Text(noteFooter)
                    }
                }

                Section {
                    LabeledContent(kind.isMoneyIn ? "Money in" : "Money out") {
                        Text(previewCents.asCurrency)
                            .font(.body.weight(.semibold).monospacedDigit())
                            .foregroundStyle(kind.isMoneyIn ? Color.green : Color.primary)
                    }
                    if kind == .sale && !saleCards.isEmpty {
                        LabeledContent("Gain") { GainText(cents: saleGainCents) }
                    }
                } footer: {
                    Text(footnote)
                }
            }
            .navigationTitle("Add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }.disabled(!canSave)
                }
            }
            .sheet(isPresented: $picking) {
                PickCardsSheet(initial: saleCards.map(\.id)) { cards in
                    saleCards = cards
                    basisTexts = CardCostRows.seeded(cards, basisTexts)
                }
            }
            .sheet(isPresented: $searchingCatalog) {
                PurchaseCatalogSheet(lines: $lines)
            }
        }
    }

    private func money(_ label: String, _ text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0.00", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .frame(maxWidth: 140)
        }
    }

    private func cardName(_ card: OwnedCard) -> String {
        card.displayName(inventory.hits[card.productId]) ?? "Card"
    }

    /// On a purchase these are added to what he paid. On an order they come
    /// off what he was paid. The same three fields, the opposite direction.
    private var extrasLabel: String {
        kind.isMoneyIn ? "What came off it" : "On top of that"
    }

    private var whoLabel: String {
        switch kind {
        case .purchase: return "Vendor, e.g. Gamecraft"
        case .sale: return "Channel, e.g. TCGplayer"
        case .grading: return "Grader, e.g. PSA"
        case .expense: return "Paid to, e.g. Amazon"
        }
    }

    private var amountLabel: String {
        switch kind {
        case .purchase: return "Item cost"
        case .sale: return "Gross"
        case .grading: return "Grading fees"
        case .expense: return "Amount"
        }
    }

    private var noteFooter: String {
        switch kind {
        case .expense: return "What you would write on a receipt. \"500 penny sleeves\"."
        default:
            return lines.isEmpty
                ? "Or write it in. What you would write on a receipt. \"6x Chaos Rising Booster Pack\"."
                : "Left blank, the purchase names the products above."
        }
    }

    private var footnote: String {
        switch kind {
        case .purchase:
            return lines.isEmpty
                ? "Nothing is identified yet. Open the purchase and scan what came out of it."
                : "The products go into inventory, and the total splits over every copy."
        case .sale:
            return saleCards.isEmpty
                ? "This records the money. With no cards attached, the gain reads as not known. You can attach cards later from the order."
                : "This records the money, and the cards are tagged sold and leave inventory."
        case .grading: return "No cards are attached. Each card keeps its own grading cost."
        case .expense: return "A cost that attaches to no card. It comes off the profit on the Summary tab."
        }
    }

    private func save() {
        guard let amountCents else { return }
        let name = who.trimmingCharacters(in: .whitespaces)

        switch kind {
        case .purchase:
            let typed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            let purchase = Purchase(
                date: date, vendor: name, note: typed.isEmpty ? PurchaseIntake.note(for: lines) : typed,
                itemCostCents: amountCents, shippingCents: shippingCents, taxCents: taxCents, feesCents: feesCents
            )
            modelContext.insert(purchase)
            if !lines.isEmpty {
                PurchaseIntake.record(lines, on: purchase, context: modelContext)
                inventory.invalidateHaystacks()
            }
            try? modelContext.save()
            onAdded(.purchase(purchase.id))

        case .sale:
            let sale = Sale(soldAt: date, channelRaw: Self.channelKey(name), grossCents: amountCents)
            sale.marketplaceFeesCents = feesCents
            sale.shippingCostCents = shippingCents
            sale.salesTaxCents = taxCents
            modelContext.insert(sale)
            try? modelContext.save()
            if !saleCards.isEmpty {
                let items = zip(saleCards, CardCostRows.typedCents(saleCards, basisTexts)).map { card, cents in
                    SaleEditor.Attachment(card: card, describedAs: card.displayName(inventory.hits[card.productId]) ?? "", basisCents: cents)
                }
                try? SaleEditor.attach(items, to: sale, context: modelContext)
                inventory.invalidateHaystacks()
            }
            onAdded(.sale(sale.id))

        case .grading:
            let submission = GradingSubmission(graderRaw: name, shippedAt: date, gradingFeesCents: amountCents)
            submission.shipToGraderCents = shippingCents
            modelContext.insert(submission)
            try? modelContext.save()
            onAdded(.grading(submission.id))

        case .expense:
            let expense = BusinessExpense(
                date: date, category: category.trimmingCharacters(in: .whitespaces), vendor: name,
                amountCents: amountCents, note: note.trimmingCharacters(in: .whitespaces)
            )
            modelContext.insert(expense)
            try? modelContext.save()
            onAdded(.expense(expense.id))
        }
        dismiss()
    }

    /// The stored form of a channel. `LedgerEntry.channelName` reads it back,
    /// so "TCGplayer" typed by hand matches the imported rows.
    static func channelKey(_ typed: String) -> String {
        let folded = typed.lowercased().trimmingCharacters(in: .whitespaces)
        switch folded {
        case "tcgplayer", "tcg player", "tcgp": return "tcgplayer"
        case "ebay": return "ebay"
        case "whatnot": return "whatnot"
        default: return folded
        }
    }
}

/// One product on a purchase that is not saved yet: how many, and which printing.
private struct PurchaseLineRow: View {
    @Binding var line: PurchaseIntake.Line

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.name).lineLimit(2)
                    Text(line.isSealed ? "Sealed · \(line.setName)" : line.setName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(line.quantity)x").monospacedDigit()
                Stepper("Quantity", value: $line.quantity, in: 1...999).labelsHidden()
            }
            if line.printings.count > 1 {
                Picker("Printing", selection: $line.printing) {
                    ForEach(line.printings, id: \.self) { Text($0).tag($0) }
                }
            }
        }
    }
}
