import SwiftData
import SwiftUI

/// Puts cards already in inventory on order, with an optional date. For the
/// things he entered before the app knew about orders, and for a stack of
/// preorders at once. See `OnOrder`.
struct OnOrderSheet: View {
    let cards: [OwnedCard]
    var onDone: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var hasExpected = false
    @State private var expected = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Expected date", isOn: $hasExpected.animation())
                    if hasExpected {
                        DatePicker("Arrives", selection: $expected, displayedComponents: .date)
                    }
                } footer: {
                    Text("Paid for, not here yet. They count in inventory once you mark them received, and they cannot be ripped or listed until then.")
                }
            }
            .navigationTitle(cards.count == 1 ? "1 on order" : "\(cards.count) on order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        OnOrder.mark(cards, expected: hasExpected ? expected : nil, context: modelContext)
                        onDone()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
