import SwiftData
import SwiftUI

/// Send raw cards to a grader. One submission, one entry per card. The fees
/// are one grading charge on the books, and no card carries them. The cards
/// are tagged "at grader" and stay in inventory, because they are still his.
struct SendToGraderSheet: View {
    var cards: [OwnedCard]
    var onSent: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var grader = "psa"
    @State private var shippedAt = Date()
    @State private var submissionNumber = ""
    @State private var serviceLevel = ""
    @State private var declaredText = ""
    @State private var feesText = ""
    @State private var shipOutText = ""
    @State private var shipBackText = ""
    @State private var insuranceText = ""

    static let graders = ["psa", "cgc"]

    private var totalCents: Int {
        (Money.cents(from: feesText) ?? 0) + (Money.cents(from: shipOutText) ?? 0)
            + (Money.cents(from: shipBackText) ?? 0) + (Money.cents(from: insuranceText) ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Grader", selection: $grader) {
                        ForEach(Self.graders, id: \.self) { Text($0.uppercased()).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    DatePicker("Shipped", selection: $shippedAt, displayedComponents: .date)
                    TextField("Submission number", text: $submissionNumber)
                    TextField("Service level, e.g. Value Bulk", text: $serviceLevel)
                    MoneyField(label: "Declared value", text: $declaredText)
                }

                Section {
                    MoneyField(label: "Grading fees", text: $feesText)
                    MoneyField(label: "Ship out", text: $shipOutText)
                    MoneyField(label: "Ship back", text: $shipBackText)
                    MoneyField(label: "Insurance", text: $insuranceText)
                } header: {
                    Text("Cost")
                } footer: {
                    Text(costDescription)
                }
            }
            .navigationTitle(cards.count == 1 ? "Send 1 card" : "Send \(cards.count) cards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { save() }.disabled(cards.isEmpty)
                }
            }
        }
    }

    private var costDescription: String {
        guard totalCents > 0 else { return "Fees can be filled in when the cards come back." }
        return "\(totalCents.asCurrency) goes on the books as one grading charge. It splits equally over the cards, and each share counts in the card's cost."
    }

    private func save() {
        let submission = GradingSubmission(graderRaw: grader, shippedAt: shippedAt, gradingFeesCents: Money.cents(from: feesText) ?? 0)
        submission.submissionNumber = submissionNumber.trimmingCharacters(in: .whitespaces)
        submission.serviceLevel = serviceLevel.trimmingCharacters(in: .whitespaces)
        submission.declaredValueCents = Money.cents(from: declaredText) ?? 0
        submission.shipToGraderCents = Money.cents(from: shipOutText) ?? 0
        submission.shipReturnCents = Money.cents(from: shipBackText) ?? 0
        submission.insuranceCents = Money.cents(from: insuranceText) ?? 0
        modelContext.insert(submission)
        for card in cards {
            modelContext.insert(GradingEntry(submission: submission, card: card))
        }
        CardTagEditor(context: modelContext).add(ReservedTag.atGrader(grader), to: cards)
        try? modelContext.save()
        onSent()
        dismiss()
    }
}
