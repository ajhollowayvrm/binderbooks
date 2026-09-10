import SwiftUI

/// One total for the selected cards, split evenly. This is how he prices a
/// batch: he knows what the lot cost, not what each card cost.
///
/// The per-card figure appears as he types, because a split he cannot see is a
/// number he cannot check.
struct CostSheet: View {
    var cardCount: Int
    /// The current total on the selection, when he is editing a price he set.
    var existingCents: Int?
    var onSet: (Int) -> Void
    var onClear: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var totalText = ""
    @FocusState private var focused: Bool

    private var totalCents: Int? { Money.cents(from: totalText) }

    private var shares: [Int] {
        guard let totalCents, cardCount > 0 else { return [] }
        return Allocation.splitEqually(totalCents, into: cardCount)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Total")
                        Spacer()
                        TextField("0.00", text: $totalText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.body.monospacedDigit())
                            .focused($focused)
                            .frame(maxWidth: 140)
                    }
                } footer: {
                    Text(splitDescription)
                }

                if existingCents != nil {
                    Section {
                        Button("Clear the price", role: .destructive) {
                            onClear()
                            dismiss()
                        }
                    } footer: {
                        Text("The purchase total covers these cards again.")
                    }
                }
            }
            .navigationTitle(cardCount == 1 ? "Cost" : "Cost for \(cardCount) cards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") {
                        if let totalCents { onSet(totalCents) }
                        dismiss()
                    }
                    .disabled(totalCents == nil)
                }
            }
            .onAppear {
                if let existingCents {
                    totalText = String(format: "%.2f", Double(existingCents) / 100)
                }
                focused = true
            }
        }
        .presentationDetents([.medium])
    }

    private var splitDescription: String {
        guard let totalCents else { return "Type what the lot cost." }
        guard cardCount > 1 else { return "\(totalCents.asCurrency) for this card." }
        let low = shares.min() ?? 0
        let high = shares.max() ?? 0
        if low == high {
            return "\(totalCents.asCurrency) over \(cardCount) cards is \(low.asCurrency) each."
        }
        // The split sums back exactly, so some cards carry one cent more.
        return "\(totalCents.asCurrency) over \(cardCount) cards is \(low.asCurrency) each, and \(high.asCurrency) on the first \(shares.filter { $0 == high }.count)."
    }
}
