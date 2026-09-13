import SwiftData
import SwiftUI

/// Change a business expense: the day, who was paid, the amount, the
/// category, and the note.
struct EditExpenseSheet: View {
    let expense: BusinessExpense

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var date: Date
    @State private var vendor: String
    @State private var category: String
    @State private var amountText: String
    @State private var note: String
    @State private var failed = false

    init(expense: BusinessExpense) {
        self.expense = expense
        _date = State(initialValue: expense.date)
        _vendor = State(initialValue: expense.vendor)
        _category = State(initialValue: expense.category)
        _amountText = State(initialValue: Money.fieldText(expense.amountCents))
        _note = State(initialValue: expense.note)
    }

    /// Nil while the amount is not money above zero.
    private var details: ExpenseEditor.Details? {
        guard let amount = Money.cents(from: amountText), amount > 0 else { return nil }
        var details = ExpenseEditor.Details(expense)
        details.date = date
        details.vendor = vendor
        details.category = category
        details.amountCents = amount
        details.note = note
        return details
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Paid to, e.g. Amazon", text: $vendor)
                        .textInputAutocapitalization(.words)
                    MoneyField(label: "Amount", text: $amountText)
                }

                Section {
                    TextField("Category, e.g. Supplies", text: $category)
                        .textInputAutocapitalization(.words)
                } footer: {
                    Text("For your own bookkeeping. Nothing is broken down by it.")
                }

                Section {
                    TextField("What it was", text: $note, axis: .vertical)
                } footer: {
                    Text("What you would write on a receipt. \"500 penny sleeves\".")
                }
            }
            .navigationTitle("Edit expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(details == nil)
                }
            }
            .alert("The expense did not save", isPresented: $failed) {
                Button("OK") {}
            } message: {
                Text("The store did not accept the change. Try again.")
            }
        }
    }

    private func save() {
        guard let details else { return }
        do {
            try ExpenseEditor.apply(details, to: expense, context: modelContext)
            dismiss()
        } catch {
            failed = true
        }
    }
}
