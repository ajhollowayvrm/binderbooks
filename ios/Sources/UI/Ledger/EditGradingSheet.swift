import SwiftData
import SwiftUI

/// Change a grading charge: the dates, the submission details, and the cost.
/// The grader changes on the charge screen, because a new grader moves the
/// cards with it. The grades change in "Edit return".
struct EditGradingSheet: View {
    let submission: GradingSubmission
    var onSaved: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var hasShipped: Bool
    @State private var shippedAt: Date
    @State private var returnedAt: Date
    @State private var submissionNumber: String
    @State private var serviceLevel: String
    @State private var declaredText: String
    @State private var feesText: String
    @State private var shipOutText: String
    @State private var shipBackText: String
    @State private var insuranceText: String
    @State private var failed = false

    init(submission: GradingSubmission, onSaved: @escaping () -> Void) {
        self.submission = submission
        self.onSaved = onSaved
        _hasShipped = State(initialValue: submission.shippedAt != nil)
        _shippedAt = State(initialValue: submission.shippedAt ?? Date())
        _returnedAt = State(initialValue: submission.returnedAt ?? Date())
        _submissionNumber = State(initialValue: submission.submissionNumber)
        _serviceLevel = State(initialValue: submission.serviceLevel)
        _declaredText = State(initialValue: Self.text(submission.declaredValueCents))
        _feesText = State(initialValue: Self.text(submission.gradingFeesCents))
        _shipOutText = State(initialValue: Self.text(submission.shipToGraderCents))
        _shipBackText = State(initialValue: Self.text(submission.shipReturnCents))
        _insuranceText = State(initialValue: Self.text(submission.insuranceCents))
    }

    private static func text(_ cents: Int) -> String {
        cents == 0 ? "" : Money.fieldText(cents)
    }

    private var details: GradingEditor.Details {
        var details = GradingEditor.Details(submission)
        details.shippedAt = hasShipped ? shippedAt : nil
        // A return date is set by "Record return", which also clears the
        // at-grader labels. This sheet only moves a date that is there.
        details.returnedAt = submission.returnedAt == nil ? nil : returnedAt
        details.submissionNumber = submissionNumber
        details.serviceLevel = serviceLevel
        details.declaredValueCents = Money.cents(from: declaredText) ?? 0
        details.gradingFeesCents = Money.cents(from: feesText) ?? 0
        details.shipToGraderCents = Money.cents(from: shipOutText) ?? 0
        details.shipReturnCents = Money.cents(from: shipBackText) ?? 0
        details.insuranceCents = Money.cents(from: insuranceText) ?? 0
        return details
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Shipped", isOn: $hasShipped)
                    if hasShipped {
                        DatePicker("Shipped on", selection: $shippedAt, displayedComponents: .date)
                    }
                    if submission.returnedAt != nil {
                        DatePicker("Returned", selection: $returnedAt, displayedComponents: .date)
                    }
                    TextField("Submission number", text: $submissionNumber)
                        .autocorrectionDisabled()
                    TextField("Service level, e.g. Value", text: $serviceLevel)
                        .textInputAutocapitalization(.words)
                    MoneyField(label: "Declared value", text: $declaredText)
                }

                Section {
                    MoneyField(label: "Grading fees", text: $feesText)
                    MoneyField(label: "Ship out", text: $shipOutText)
                    MoneyField(label: "Ship back", text: $shipBackText)
                    MoneyField(label: "Insurance", text: $insuranceText)
                    LabeledContent("Total") {
                        Text(details.totalCostCents.asCurrency).font(.body.weight(.semibold).monospacedDigit())
                    }
                } header: {
                    Text("Cost")
                } footer: {
                    Text(costFooter)
                }
            }
            .navigationTitle("Edit grading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .alert("The charge did not save", isPresented: $failed) {
                Button("OK") {}
            } message: {
                Text("The store did not accept the change. Try again.")
            }
        }
    }

    private var costFooter: String {
        let count = submission.entries.count
        switch count {
        case 0: return "No cards are on this charge, so the cost stays on the charge."
        case 1: return "A new total becomes the card's grading cost."
        default: return "A new total splits equally over the \(count) cards, and each card's grading cost changes with it."
        }
    }

    private func save() {
        do {
            try GradingEditor.apply(details, to: submission, context: modelContext)
            onSaved()
            dismiss()
        } catch {
            failed = true
        }
    }
}
