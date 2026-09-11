import SwiftData
import SwiftUI

/// Send raw cards to a grader. One submission, one entry per card, the fees
/// split evenly across them. The cards are tagged "at grader" and stay in
/// inventory, because they are still his.
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

    private var shares: [Int] { Allocation.splitEqually(totalCents, into: cards.count) }

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
                    Text(splitDescription)
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

    private var splitDescription: String {
        guard totalCents > 0 else { return "Fees can be filled in when the cards come back." }
        let low = shares.min() ?? 0
        let high = shares.max() ?? 0
        if cards.count == 1 { return "\(totalCents.asCurrency) on this card." }
        if low == high { return "\(totalCents.asCurrency) over \(cards.count) cards is \(low.asCurrency) each." }
        return "\(totalCents.asCurrency) over \(cards.count) cards is \(low.asCurrency) each, and \(high.asCurrency) on the first \(shares.filter { $0 == high }.count)."
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
        Allocation.allocate(submission)
        // The fee lands on the cards now, not when they come back. The return
        // sheet re-allocates and overwrites these with the real invoice.
        Allocation.capitalise(submission)
        CardTagEditor(context: modelContext).add(ReservedTag.atGrader(grader), to: cards)
        try? modelContext.save()
        onSent()
        dismiss()
    }
}
