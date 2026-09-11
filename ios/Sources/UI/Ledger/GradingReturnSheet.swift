import SwiftData
import SwiftUI

/// The cards came back. Grades and cert numbers land on the entries, the cert
/// lands on the card so it renders as a slab, and each card's share of the
/// fees becomes its grading basis.
///
/// Fees are editable here too, because the grader's invoice often arrives
/// after the cards were sent.
struct GradingReturnSheet: View {
    let submission: GradingSubmission
    var onReturned: () -> Void

    @Environment(InventoryModel.self) private var inventory
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    struct Draft: Identifiable {
        let id: UUID
        var gradeText: String
        var cert: String
        var noGrade: Bool
    }

    @State private var returnedAt: Date
    @State private var drafts: [Draft]
    @State private var feesText: String
    @State private var shipOutText: String
    @State private var shipBackText: String
    @State private var insuranceText: String

    init(submission: GradingSubmission, onReturned: @escaping () -> Void) {
        self.submission = submission
        self.onReturned = onReturned
        _returnedAt = State(initialValue: submission.returnedAt ?? Date())
        _drafts = State(initialValue: submission.entries
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { entry in
                Draft(
                    id: entry.id,
                    gradeText: entry.grade.map { Self.gradeText($0) } ?? "",
                    cert: entry.certNumber,
                    noGrade: entry.noGrade
                )
            })
        _feesText = State(initialValue: submission.gradingFeesCents > 0 ? Money.fieldText(submission.gradingFeesCents) : "")
        _shipOutText = State(initialValue: submission.shipToGraderCents > 0 ? Money.fieldText(submission.shipToGraderCents) : "")
        _shipBackText = State(initialValue: submission.shipReturnCents > 0 ? Money.fieldText(submission.shipReturnCents) : "")
        _insuranceText = State(initialValue: submission.insuranceCents > 0 ? Money.fieldText(submission.insuranceCents) : "")
    }

    private var totalCents: Int {
        (Money.cents(from: feesText) ?? 0) + (Money.cents(from: shipOutText) ?? 0)
            + (Money.cents(from: shipBackText) ?? 0) + (Money.cents(from: insuranceText) ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Returned", selection: $returnedAt, displayedComponents: .date)
                }

                Section {
                    ForEach($drafts) { $draft in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(name(for: draft.id))
                                .font(.headline)
                            HStack {
                                TextField("Grade, e.g. 10 or Pristine 10", text: $draft.gradeText)
                                    .disabled(draft.noGrade)
                                TextField("Cert number", text: $draft.cert)
                                    .keyboardType(.numberPad)
                                    .disabled(draft.noGrade)
                            }
                            Toggle("No grade", isOn: $draft.noGrade)
                                .font(.subheadline)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Cards")
                } footer: {
                    Text("No grade covers N0, altered, and rejected. The card still carries its share of the fees.")
                }

                Section {
                    MoneyField(label: "Grading fees", text: $feesText)
                    MoneyField(label: "Ship out", text: $shipOutText)
                    MoneyField(label: "Ship back", text: $shipBackText)
                    MoneyField(label: "Insurance", text: $insuranceText)
                } header: {
                    Text("Cost")
                } footer: {
                    Text(feeDescription)
                }
            }
            .navigationTitle("Record return")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
    }

    private var feeDescription: String {
        let count = drafts.count
        guard count > 0, totalCents > 0 else { return "Each card's share becomes its grading basis." }
        let shares = Allocation.splitEqually(totalCents, into: count)
        let low = shares.min() ?? 0
        return "\(totalCents.asCurrency) over \(count) cards is \(low.asCurrency) each. That share becomes each card's grading basis."
    }

    private func name(for entryID: UUID) -> String {
        guard let card = submission.entries.first(where: { $0.id == entryID })?.card else { return "Unknown" }
        return inventory.hits[card.productId]?.name ?? card.ocrName ?? "Unknown"
    }

    /// "10", not "10.0". A half grade keeps its half.
    static func gradeText(_ grade: Double) -> String {
        grade == grade.rounded() ? String(Int(grade)) : String(grade)
    }

    /// The number inside what he typed. "Pristine 10" is a 10; "9.5" is 9.5.
    static func gradeNumber(in label: String) -> Double? {
        label.split(whereSeparator: \.isWhitespace).reversed().lazy.compactMap { Double($0) }.first
    }

    private func save() {
        submission.returnedAt = returnedAt
        submission.gradingFeesCents = Money.cents(from: feesText) ?? 0
        submission.shipToGraderCents = Money.cents(from: shipOutText) ?? 0
        submission.shipReturnCents = Money.cents(from: shipBackText) ?? 0
        submission.insuranceCents = Money.cents(from: insuranceText) ?? 0
        Allocation.allocate(submission)

        let editor = CardTagEditor(context: modelContext)
        for draft in drafts {
            guard let entry = submission.entries.first(where: { $0.id == draft.id }) else { continue }
            let cert = draft.cert.trimmingCharacters(in: .whitespaces)
            let gradeLabel = draft.gradeText.trimmingCharacters(in: .whitespaces)
            entry.noGrade = draft.noGrade
            entry.grade = draft.noGrade ? nil : Self.gradeNumber(in: gradeLabel)
            entry.certNumber = draft.noGrade ? "" : cert

            guard let card = entry.card else { continue }
            card.gradingBasisCents = entry.allocatedFeeCents
            if !draft.noGrade, !cert.isEmpty {
                card.certNumber = cert
                card.graderRaw = submission.graderRaw
                card.gradeLabel = gradeLabel.isEmpty ? nil : gradeLabel
            }
            for label in ReservedTag.allAtGrader { editor.remove(label, from: [card]) }
            if !draft.noGrade {
                editor.add(ReservedTag.graded, to: [card])
            }
        }
        try? modelContext.save()
        onReturned()
        dismiss()
    }
}
