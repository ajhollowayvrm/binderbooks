import SwiftUI

/// Two sweeps over a scan session, before the commit.
///
/// A bulk rip leaves two kinds of row he never wants in the collection: the
/// penny cards, and the rows the matcher could not place. Deleting them one
/// swipe at a time is the slowest part of a 45-card review.
///
/// Both sweeps read the whole session, not the rows the filter chip leaves on
/// the screen, so the counts here are the counts he gets.
struct CleanUpSheet: View {
    let model: ScanSessionModel
    var onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var thresholdText = "0.01"
    @State private var confirming: Sweep?

    private enum Sweep: Identifiable {
        case cheap, unknown
        var id: Self { self }
    }

    /// Nil while the field holds no number.
    private var thresholdCents: Int? { Money.cents(from: thresholdText) }

    private var cheap: [OwnedCard] { thresholdCents.map { model.cardsWorth(atMost: $0) } ?? [] }
    private var unknown: [OwnedCard] { model.unidentifiedCards }

    /// The two sweeps overlap: an unidentified card has no price and no sweep
    /// counts it twice, but a hand-entered card can be in both.
    private var kept: Int {
        model.cards.count - Set(cheap.map(\.id)).union(unknown.map(\.id)).count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    MoneyField(label: "Worth this or less", text: $thresholdText)
                    HStack(spacing: 8) {
                        ForEach([1, 5, 10, 25, 100], id: \.self) { cents in
                            Chip(title: cents.asCurrency, isSelected: thresholdCents == cents) {
                                thresholdText = Money.fieldText(cents)
                            }
                        }
                    }
                    Button(role: .destructive) {
                        confirming = .cheap
                    } label: {
                        Label("Remove \(cheap.count) \(cheap.count == 1 ? "card" : "cards")", systemImage: "trash")
                    }
                    .disabled(cheap.isEmpty)
                } header: {
                    Text("Cheap cards")
                } footer: {
                    Text("A card with no price stays, because an unpriced card is unknown and not cheap. A slab stays, because the price here is the raw card's.")
                }

                Section {
                    Button(role: .destructive) {
                        confirming = .unknown
                    } label: {
                        Label("Remove \(unknown.count) \(unknown.count == 1 ? "card" : "cards")", systemImage: "trash")
                    }
                    .disabled(unknown.isEmpty)
                } header: {
                    Text("Unknown cards")
                } footer: {
                    Text("The rows no card stands behind. The matcher placed none of them, and you typed none of them in by hand.")
                }

                Section {
                    LabeledContent("In the session now", value: "\(model.cards.count)")
                    LabeledContent("Both sweeps leave", value: "\(kept)")
                }
            }
            .navigationTitle("Clean up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(title(for: confirming), isPresented: Binding(
                get: { confirming != nil },
                set: { if !$0 { confirming = nil } }
            ), titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    remove(confirming == .cheap ? cheap : unknown)
                }
            }
        }
    }

    private func title(for sweep: Sweep?) -> String {
        switch sweep {
        case .cheap:
            let cents = thresholdCents ?? 0
            return "Remove \(cheap.count) cards worth \(cents.asCurrency) or less?"
        case .unknown:
            return "Remove \(unknown.count) cards no card stands behind?"
        case nil:
            return ""
        }
    }

    private func remove(_ cards: [OwnedCard]) {
        guard !cards.isEmpty else { return }
        model.delete(cards)
        confirming = nil
        onDeleted()
        // The session is empty, so there is nothing left to sweep.
        if model.cards.isEmpty { dismiss() }
    }
}
