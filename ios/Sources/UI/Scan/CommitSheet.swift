import SwiftData
import SwiftUI

/// Attach the session to a purchase. Pick a recent one, or create one inline:
/// vendor, date, total, note. That is the whole form.
///
/// Every field is optional. A blank form commits the cards with no purchase at
/// all, because he logs cards he was given, cards he traded for, and cards
/// whose cost he does not want to type tonight. A vendor with no total records
/// the purchase at zero, and he can set the total later in the ledger.
///
/// A session started from a purchase arrives with that purchase already chosen,
/// because he opened the pack from it and there is nothing left to ask.
struct CommitSheet: View {
    let model: ScanSessionModel
    var onDone: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var vendor = ""
    @State private var date = Date()
    @State private var totalText = ""
    @State private var note = ""
    @State private var existing: Purchase?
    @State private var picking = false

    private var totalCents: Int? { Money.cents(from: totalText) }

    private var unpricedCount: Int {
        model.cards.filter { !$0.basisIsManual && !$0.isBulk }.count
    }

    /// The total covers everything. What he priced comes out first, and the
    /// rest splits over the cards he did not price.
    private var splitNote: String {
        let manual = model.manualBasisCents
        guard let total = totalCents else {
            return "\(manual.asCurrency) of this total is already set on \(model.pricedCardCount) cards."
        }
        if manual > total {
            return "The prices you set come to \(manual.asCurrency), which is more than this total. Nothing you typed will change, and the rest splits nothing."
        }
        guard unpricedCount > 0 else {
            return "The prices you set come to \(manual.asCurrency). Every card is priced, so nothing splits."
        }
        return "\(manual.asCurrency) is already set on \(model.pricedCardCount) cards. The remaining \((total - manual).asCurrency) splits over \(unpricedCount)."
    }
    /// True when he typed something that describes a purchase. A blank form
    /// makes no purchase, so the cards commit on their own.
    private var makesPurchase: Bool {
        !vendor.trimmingCharacters(in: .whitespaces).isEmpty
            || !note.trimmingCharacters(in: .whitespaces).isEmpty
            || !totalText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The only thing that can block a commit is a total he typed wrong.
    private var canCommit: Bool {
        existing != nil || totalText.isEmpty || totalCents != nil
    }

    private var commitNote: String {
        if existing != nil { return "The cards join that purchase." }
        if !makesPurchase { return "No purchase. The cards join the inventory with no cost, and the ledger does not change." }
        if totalCents == nil { return "A purchase at \(0.asCurrency). Set the total later in the ledger." }
        return splitNote
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Cards", value: "\(model.cards.count)")
                    LabeledContent("Tracked", value: "\(model.cards.filter { !$0.isBulk }.count)")
                    if model.pricedCardCount > 0 {
                        LabeledContent("Priced at review", value: "\(model.pricedCardCount) · \(model.manualBasisCents.asCurrency)")
                    }
                    LabeledContent("Market", value: model.sessionTotalCents.asCurrency)
                }

                Section {
                    TextField("Vendor, e.g. Walmart", text: $vendor)
                        .disabled(existing != nil)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .disabled(existing != nil)
                    HStack {
                        Text("Total")
                        Spacer()
                        TextField("0.00", text: $totalText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .disabled(existing != nil)
                        if !totalText.isEmpty, totalCents == nil {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                        }
                    }
                    TextField("Note", text: $note, axis: .vertical)
                        .disabled(existing != nil)
                } header: {
                    Text("New purchase — optional")
                } footer: {
                    Text(commitNote)
                }

                Section {
                    Button {
                        picking = true
                    } label: {
                        chosenRow
                    }
                    .buttonStyle(.plain)
                    if existing != nil {
                        Button("Attach to no purchase", role: .destructive) { existing = nil }
                    }
                } header: {
                    Text("Or attach to a purchase")
                } footer: {
                    Text("Search every purchase on the books by vendor, product, amount, or date. The ones bought around today come first.")
                }
            }
            .navigationTitle("Commit")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $picking) { picker }
            .onAppear {
                if existing == nil { existing = model.session.purchase }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Commit") { commit() }
                        .disabled(!canCommit)
                }
            }
        }
    }

    /// The purchase he has chosen, or the invitation to choose one. It carries
    /// the same lines as a picker row, so the row he tapped is the row he sees.
    @ViewBuilder
    private var chosenRow: some View {
        if let existing {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(existing.vendor.isEmpty ? "Purchase" : existing.vendor)
                    Text("\(existing.date.formatted(date: .abbreviated, time: .omitted)) · \(LedgerEntry.purchaseContents(existing))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !existing.note.isEmpty {
                        Text(existing.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Text(existing.landedCostCents.asCurrency)
                    .font(.callout.monospacedDigit())
            }
            .contentShape(Rectangle())
        } else {
            LabeledContent("Purchase", value: "Choose…")
                .contentShape(Rectangle())
        }
    }

    private var picker: some View {
        NavigationStack {
            PurchasePickerList(
                around: date,
                footer: "The cards take their share of that purchase's total. A cost already on a card stays, and it comes out of the total first.",
                isCurrent: { $0.id == existing?.id },
                leading: {
                    Button("No purchase") {
                        existing = nil
                        picking = false
                    }
                },
                onPick: { purchase in
                    existing = purchase
                    picking = false
                }
            )
            .navigationTitle("Attach to a purchase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { picking = false }
                }
            }
        }
    }

    private func commit() {
        let purchase: Purchase?
        if let existing {
            purchase = existing
        } else if makesPurchase {
            let created = Purchase(
                date: date,
                vendor: vendor.trimmingCharacters(in: .whitespaces),
                note: note,
                itemCostCents: totalCents ?? 0
            )
            modelContext.insert(created)
            purchase = created
        } else {
            purchase = nil
        }
        model.commit(to: purchase)
        onDone()
    }
}
