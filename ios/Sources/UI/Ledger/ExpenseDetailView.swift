import SwiftData
import SwiftUI

/// One business expense: what it was, and what it cost.
///
/// An expense attaches to no card, so there is nothing here to unlink and
/// nothing blocks the delete.
struct ExpenseDetailView: View {
    let expenseID: UUID

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var expenses: [BusinessExpense]
    @State private var confirmDelete = false

    init(expenseID: UUID) {
        self.expenseID = expenseID
        _expenses = Query(filter: #Predicate<BusinessExpense> { $0.id == expenseID })
    }

    private var expense: BusinessExpense? { expenses.first }

    var body: some View {
        List {
            if let expense {
                Section {
                    LabeledContent("Date", value: expense.date.formatted(date: .abbreviated, time: .omitted))
                    if !expense.vendor.isEmpty {
                        LabeledContent("Paid to", value: expense.vendor)
                    }
                    if !expense.category.isEmpty {
                        LabeledContent("Category", value: expense.category)
                    }
                    LabeledContent("Amount") {
                        Text(expense.amountCents.asCurrency)
                            .font(.body.weight(.semibold).monospacedDigit())
                    }
                }

                if !expense.note.isEmpty {
                    Section("What it was") {
                        Text(expense.note)
                    }
                }

                Section {
                    Button("Delete expense", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("This comes off the profit on the Summary tab. It attaches to no card.")
                }
            } else {
                ContentUnavailableView("This expense is gone", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle("Expense")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this expense?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteExpense() }
        }
    }

    private func deleteExpense() {
        guard let expense else { return }
        modelContext.delete(expense)
        try? modelContext.save()
        dismiss()
    }
}
