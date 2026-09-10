import SwiftData
import SwiftUI

/// Attach the session to a purchase. Pick a recent one, or create one inline:
/// vendor, date, total, note. That is the whole form.
struct CommitSheet: View {
    let model: ScanSessionModel
    var onDone: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Purchase.date, order: .reverse) private var purchases: [Purchase]

    @State private var vendor = ""
    @State private var date = Date()
    @State private var totalText = ""
    @State private var note = ""
    @State private var existing: Purchase?

    private var totalCents: Int? { Money.cents(from: totalText) }
    private var canCommit: Bool {
        existing != nil || (!vendor.trimmingCharacters(in: .whitespaces).isEmpty && totalCents != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Cards", value: "\(model.cards.count)")
                    LabeledContent("Tracked", value: "\(model.cards.filter { !$0.isBulk }.count)")
                    LabeledContent("Market", value: model.sessionTotalCents.asCurrency)
                }

                Section("New purchase") {
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
                }

                if !purchases.isEmpty {
                    Section("Or attach to a recent purchase") {
                        ForEach(purchases.prefix(12)) { purchase in
                            Button {
                                existing = existing == purchase ? nil : purchase
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(purchase.vendor.isEmpty ? "Purchase" : purchase.vendor)
                                            .foregroundStyle(.primary)
                                        Text("\(purchase.date.formatted(date: .abbreviated, time: .omitted)) · \(purchase.landedCostCents.asCurrency) · \(purchase.items.count) lines")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if existing == purchase {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Commit")
            .navigationBarTitleDisplayMode(.inline)
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

    private func commit() {
        let purchase: Purchase
        if let existing {
            purchase = existing
        } else {
            guard let cents = totalCents else { return }
            purchase = Purchase(date: date, vendor: vendor.trimmingCharacters(in: .whitespaces), note: note, itemCostCents: cents)
            modelContext.insert(purchase)
        }
        model.commit(to: purchase)
        onDone()
    }
}
