import SwiftData
import SwiftUI

/// Record money by hand: a purchase, an order, a grading charge, or an expense.
///
/// This writes the money. A purchase can also take what came in it, found in
/// the catalog: each product is recorded on the purchase and goes into
/// inventory, and the purchase's cost splits over those cards by market price. A note alone is
/// enough, for a purchase the catalog does not describe. An order can also
/// take the cards that sold, picked from inventory: each card goes on the
/// order and is tagged sold.
struct AddTransactionSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case purchase = "Purchase"
        case sale = "Order"
        case grading = "Grading"
        case expense = "Expense"

        var id: String { rawValue }
        var isMoneyIn: Bool { self == .sale }
        /// For the plus menu on the landing screen, where the four kinds are
        /// rows instead of segments.
        var symbol: String {
            switch self {
            case .purchase: return "cart"
            case .sale: return "tag"
            case .grading: return "seal"
            case .expense: return "dollarsign.circle"
            }
        }
        /// An expense is one amount. Nothing rides on top of it and nothing
        /// comes off it, so the three extra fields would only be empty rows.
        var hasExtras: Bool { self != .expense }
        /// Money out has a receipt. An order's record is the marketplace's.
        var takesReceipts: Bool { self != .sale }
    }

    var onAdded: (LedgerEntry.Kind) -> Void

    /// The kind the sheet opens on. The ledger's plus opens on a purchase; the
    /// plus menu on the landing screen names the kind, because there the
    /// choice was already made.
    /// `receipts` are files shared in from another app. The sheet reads them
    /// when it opens, the same way it reads a receipt picked in the sheet.
    init(kind: Kind = .purchase, receipts: [ReceiptFile] = [], onAdded: @escaping (LedgerEntry.Kind) -> Void) {
        self.onAdded = onAdded
        self.sharedReceipts = receipts
        _kind = State(initialValue: kind)
    }

    private let sharedReceipts: [ReceiptFile]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(InventoryModel.self) private var inventory

    @State private var kind: Kind
    @State private var date = Date()
    @State private var who = ""
    @State private var category = ""
    @State private var note = ""
    @State private var amountText = ""
    @State private var feesText = ""
    @State private var shippingText = ""
    @State private var taxText = ""
    @State private var saleCards: [OwnedCard] = []
    @State private var picking = false
    @State private var lines: [PurchaseIntake.Line] = []
    @State private var searchingCatalog = false
    @State private var receipts: [ReceiptFile] = []
    @State private var readingReceipt = false
    /// The fields the receipt filled, so the sheet can say to check them.
    @State private var filledFromReceipt = false
    /// What the receipts say, and the money fields as the receipt filled them.
    /// A new kind fills the money again while he has not changed it.
    @State private var receiptDraft: ReceiptDraft?
    @State private var filledMoney: [String] = []

    private var moneyFields: [String] { [amountText, feesText, shippingText, taxText] }

    private var amountCents: Int? { Money.cents(from: amountText) }
    private var feesCents: Int { Money.cents(from: feesText) ?? 0 }
    private var shippingCents: Int { Money.cents(from: shippingText) ?? 0 }
    private var taxCents: Int { Money.cents(from: taxText) ?? 0 }

    private var canSave: Bool {
        // A purchase can be $0: he paid with store credit. Its cards come in
        // at $0. Every other kind is money that moved, so it needs an amount.
        guard let amountCents, amountCents > 0 || (kind == .purchase && amountCents == 0) else { return false }
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                if kind.takesReceipts {
                    receiptSection
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
                        ForEach(saleCards) { Text(cardName($0)) }
                        Button {
                            picking = true
                        } label: {
                            Label(saleCards.isEmpty ? "Attach cards" : "Change cards", systemImage: "plus")
                        }
                    } header: {
                        Text("Cards")
                    } footer: {
                        Text("Pick the cards that sold, from inventory.")
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
                             ? "Find the sealed product or the cards. Each one is recorded on the purchase and goes into inventory."
                             : "Each one is recorded on the purchase and goes into inventory. Swipe a row to take it off.")
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
                }
            }
            .sheet(isPresented: $searchingCatalog) {
                PurchaseCatalogSheet(lines: $lines)
            }
            .task {
                if !sharedReceipts.isEmpty && receipts.isEmpty { addReceipts(sharedReceipts) }
            }
            // A purchase splits the total into item, shipping, and tax. An
            // expense is the total. The same receipt fills each kind its way.
            .onChange(of: kind) {
                guard let receiptDraft, moneyFields == filledMoney else { return }
                amountText = ""; feesText = ""; shippingText = ""; taxText = ""
                fillMoney(from: receiptDraft)
            }
        }
    }

    /// The receipt comes first. What it says fills the fields below it.
    private var receiptSection: some View {
        Section {
            ForEach(Array(receipts.enumerated()), id: \.element.id) { index, file in
                ReceiptRow(kind: file.kind, data: file.data, fileName: file.fileName, index: index)
            }
            .onDelete { receipts.remove(atOffsets: $0) }
            AddReceiptMenu(onAdd: addReceipts, reading: $readingReceipt) {
                if readingReceipt {
                    HStack { ProgressView(); Text("Reading the receipt…") }
                } else {
                    Label(receipts.isEmpty ? "Add a receipt" : "Add another page", systemImage: "paperclip")
                }
            }
        } header: {
            Text("Receipt")
        } footer: {
            Text(filledFromReceipt
                 ? "The fields below come from the receipt. Check each one before you add."
                 : "Scan a paper receipt, or pick a screenshot or a PDF. The app fills in what it can read.")
        }
    }

    /// Fills each empty field from what the receipts say. A field he already
    /// typed stays. All the receipts are read together, because the total of
    /// a long receipt is on its last page.
    private func addReceipts(_ files: [ReceiptFile]) {
        receipts.append(contentsOf: files)
        let draft = ReceiptParser.parse(receipts.flatMap(\.lines), knownVendors: ledgerVendors())
        var filled = false

        if draft.looksLikeGrading, kind == .purchase, amountText.isEmpty {
            kind = .grading
        }
        if let receiptDate = draft.date, Calendar.current.isDateInToday(date), !Calendar.current.isDateInToday(receiptDate) {
            date = receiptDate
            filled = true
        }
        if who.trimmingCharacters(in: .whitespaces).isEmpty, let vendor = draft.vendor {
            who = vendor
            filled = true
        }
        if moneyFields.allSatisfy(\.isEmpty) || moneyFields == filledMoney {
            amountText = ""; feesText = ""; shippingText = ""; taxText = ""
            filled = fillMoney(from: draft) || filled
        }
        receiptDraft = draft
        filledFromReceipt = filledFromReceipt || filled
    }

    /// Writes the draft's money into the empty fields for the current kind.
    @discardableResult
    private func fillMoney(from draft: ReceiptDraft) -> Bool {
        var filled = false
        switch kind {
        case .purchase:
            if let fields = draft.purchaseFields {
                amountText = Money.fieldText(fields.itemCents)
                shippingText = fields.shippingCents == 0 ? "" : Money.fieldText(fields.shippingCents)
                taxText = fields.taxCents == 0 ? "" : Money.fieldText(fields.taxCents)
                filled = true
            }
        case .grading:
            if let fields = draft.gradingFields {
                amountText = Money.fieldText(fields.feesCents)
                shippingText = fields.shippingCents == 0 ? "" : Money.fieldText(fields.shippingCents)
                filled = true
            }
        case .expense:
            if let cents = draft.expenseCents {
                amountText = Money.fieldText(cents)
                filled = true
            }
        case .sale:
            break
        }
        filledMoney = moneyFields
        return filled
    }

    /// The vendors, graders, and payees already on the books, so a receipt
    /// from a store he has used before gets the ledger's spelling.
    private func ledgerVendors() -> [String] {
        let purchases = (try? modelContext.fetch(FetchDescriptor<Purchase>())) ?? []
        let expenses = (try? modelContext.fetch(FetchDescriptor<BusinessExpense>())) ?? []
        let grading = (try? modelContext.fetch(FetchDescriptor<GradingSubmission>())) ?? []
        let names = purchases.map(\.vendor) + expenses.map(\.vendor) + grading.map(\.graderRaw)
        return Array(Set(names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
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
                ? "The purchase counts in your profit and loss. It puts no cost on a card, because no card is on it."
                : "The products go into inventory. The landed cost splits over them by market price."
        case .sale:
            return saleCards.isEmpty
                ? "This records the money. You can attach cards later from the order."
                : "This records the money, and the cards are tagged sold and leave inventory."
        case .grading: return "No cards are attached."
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
            ReceiptOwner.purchase(purchase).attach(receipts, context: modelContext)
            onAdded(.purchase(purchase.id))
            if !lines.isEmpty {
                // The split reads market prices, so the products load first.
                // The sheet closes at once. The context outlives it.
                let lines = lines
                let context = modelContext
                let inventory = inventory
                Task { @MainActor in
                    await inventory.load(productIds: lines.map(\.productId))
                    PurchaseIntake.record(lines, on: purchase, marketCents: { inventory.marketCents(for: $0) }, context: context)
                    try? context.save()
                    inventory.invalidateHaystacks()
                }
            }

        case .sale:
            let sale = Sale(soldAt: date, channelRaw: Self.channelKey(name), grossCents: amountCents)
            sale.marketplaceFeesCents = feesCents
            sale.shippingCostCents = shippingCents
            sale.salesTaxCents = taxCents
            modelContext.insert(sale)
            try? modelContext.save()
            if !saleCards.isEmpty {
                let items = saleCards.map { card in
                    SaleEditor.Attachment(card: card, describedAs: card.displayName(inventory.hits[card.productId]) ?? "")
                }
                try? SaleEditor.attach(items, to: sale, context: modelContext)
                inventory.invalidateHaystacks()
            }
            onAdded(.sale(sale.id))

        case .grading:
            let submission = GradingSubmission(graderRaw: name, shippedAt: date, gradingFeesCents: amountCents)
            submission.shipToGraderCents = shippingCents
            modelContext.insert(submission)
            ReceiptOwner.grading(submission).attach(receipts, context: modelContext)
            onAdded(.grading(submission.id))

        case .expense:
            let expense = BusinessExpense(
                date: date, category: category.trimmingCharacters(in: .whitespaces), vendor: name,
                amountCents: amountCents, note: note.trimmingCharacters(in: .whitespaces)
            )
            modelContext.insert(expense)
            ReceiptOwner.expense(expense).attach(receipts, context: modelContext)
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
