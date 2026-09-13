import SwiftData
import SwiftUI

/// Change what a card cost and the day it arrived.
struct EditCardCostSheet: View {
    let card: OwnedCard
    var onSaved: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var acquiredAt: Date
    @State private var costText: String
    @State private var gradingText: String
    @State private var usesSplit: Bool
    @State private var failed = false
    /// Fixed when the sheet opens, so the toggle does not vanish as it moves.
    private let offersSplit: Bool

    init(card: OwnedCard, onSaved: @escaping () -> Void) {
        self.card = card
        self.onSaved = onSaved
        let details = CardEditor.CostDetails(card)
        _acquiredAt = State(initialValue: details.acquiredAt)
        _costText = State(initialValue: Self.text(details.acquisitionBasisCents))
        _gradingText = State(initialValue: Self.text(details.gradingBasisCents))
        _usesSplit = State(initialValue: details.usesSplit)
        offersSplit = details.usesSplit || CardEditor.canUseSplit(card)
    }

    private static func text(_ cents: Int) -> String {
        cents == 0 ? "" : Money.fieldText(cents)
    }

    /// A blank field is zero. Nil while a field holds text that is not money.
    private static func cents(_ text: String) -> Int? {
        text.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : Money.cents(from: text)
    }

    private var details: CardEditor.CostDetails? {
        guard let cost = Self.cents(costText), let grading = Self.cents(gradingText) else { return nil }
        var details = CardEditor.CostDetails(card)
        details.acquiredAt = acquiredAt
        details.acquisitionBasisCents = cost
        details.gradingBasisCents = grading
        details.usesSplit = usesSplit
        return details
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Acquired", selection: $acquiredAt, displayedComponents: .date)
                }

                Section {
                    if offersSplit {
                        Toggle("Use its share of the purchase", isOn: $usesSplit)
                    }
                    if usesSplit {
                        LabeledContent("Share now", value: card.acquisitionBasisCents.asCurrency)
                    } else {
                        MoneyField(label: "What it cost", text: $costText)
                    }
                } header: {
                    Text("Cost")
                } footer: {
                    Text(costFooter)
                }

                Section {
                    MoneyField(label: "Grading cost", text: $gradingText)
                } footer: {
                    Text("A change to a grading charge's total writes over this figure.")
                }
            }
            .navigationTitle("Edit cost")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(details == nil)
                }
            }
            .alert("The cost did not save", isPresented: $failed) {
                Button("OK") {}
            } message: {
                Text("The store did not accept the change. Try again.")
            }
        }
    }

    private var costFooter: String {
        if usesSplit {
            return "This card takes an equal share of what its purchase cost. Turn this off to type what the card cost."
        }
        guard card.sourceItem?.purchase != nil else { return "What you paid for this card." }
        return CardEditor.canUseSplit(card)
            ? "A typed cost is this card's own. It comes out of the purchase total, and the rest splits over the other cards."
            : "A typed cost is this card's own. The other cards from this purchase keep their cost."
    }

    private func save() {
        guard let details else { return }
        do {
            try CardEditor.apply(details, to: card, context: modelContext)
            onSaved()
            dismiss()
        } catch {
            failed = true
        }
    }
}
