import SwiftData
import SwiftUI

/// Record money by hand: a purchase, an order, or a grading charge.
///
/// This writes the money and nothing else. An order recorded here carries no
/// cards, so it reads "gain not known" and it does not mark anything sold —
/// the same shape as the 35 imported orders that recorded a price and no
/// lines. Selling a card out of inventory is its own flow, and it is not built.
struct AddTransactionSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case purchase = "Purchase"
        case sale = "Order"
        case grading = "Grading"

        var id: String { rawValue }
        var isMoneyIn: Bool { self == .sale }
    }

    var onAdded: (LedgerEntry.Kind) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var kind: Kind = .purchase
    @State private var date = Date()
    @State private var who = ""
    @State private var note = ""
    @State private var amountText = ""
    @State private var feesText = ""
    @State private var shippingText = ""
    @State private var taxText = ""

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

                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField(whoLabel, text: $who)
                        .textInputAutocapitalization(.words)
                    money(amountLabel, $amountText)
                }

                Section(extrasLabel) {
                    money("Fees", $feesText)
                    money(kind == .grading ? "Shipping both ways" : "Shipping", $shippingText)
                    if kind != .grading { money("Sales tax", $taxText) }
                }

                if kind == .purchase {
                    Section {
                        TextField("What it was", text: $note, axis: .vertical)
                    } footer: {
                        Text("What you would write on a receipt. \"6x Chaos Rising Booster Pack\".")
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
        }
    }

    private var amountLabel: String {
        switch kind {
        case .purchase: return "Item cost"
        case .sale: return "Gross"
        case .grading: return "Grading fees"
        }
    }

    private var footnote: String {
        switch kind {
        case .purchase: return "Nothing is identified yet. Open the purchase and scan what came out of it."
        case .sale: return "This records the money. It does not mark a card sold, and the gain reads as not known until a card is attached."
        case .grading: return "No cards are attached. Each card keeps its own grading cost."
        }
    }

    private func save() {
        guard let amountCents else { return }
        let name = who.trimmingCharacters(in: .whitespaces)

        switch kind {
        case .purchase:
            let purchase = Purchase(
                date: date, vendor: name, note: note.trimmingCharacters(in: .whitespaces),
                itemCostCents: amountCents, shippingCents: shippingCents, taxCents: taxCents, feesCents: feesCents
            )
            modelContext.insert(purchase)
            try? modelContext.save()
            onAdded(.purchase(purchase.id))

        case .sale:
            let sale = Sale(soldAt: date, channelRaw: Self.channelKey(name), grossCents: amountCents)
            sale.marketplaceFeesCents = feesCents
            sale.shippingCostCents = shippingCents
            sale.salesTaxCents = taxCents
            modelContext.insert(sale)
            try? modelContext.save()
            onAdded(.sale(sale.id))

        case .grading:
            let submission = GradingSubmission(graderRaw: name, shippedAt: date, gradingFeesCents: amountCents)
            submission.shipToGraderCents = shippingCents
            modelContext.insert(submission)
            try? modelContext.save()
            onAdded(.grading(submission.id))
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
