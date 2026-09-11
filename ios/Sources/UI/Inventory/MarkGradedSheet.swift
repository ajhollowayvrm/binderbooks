import SwiftData
import SwiftUI

/// Record the grade a card came back at, without a submission.
///
/// The grading return flow reads a `GradingSubmission`'s entries, and the
/// imported charges name a card count and no cards (docs/04), so the 40 cards
/// he already had out had no way to be marked graded at all. This is that way:
/// it writes the same fields the return flow writes — grader, grade, cert —
/// and swaps the "at PSA" / "at CGC" label for "graded".
///
/// It takes a list, so one card from its own screen and thirty from a
/// selection are the same sheet. The grade is per card, because a submission
/// comes back at several grades.
struct MarkGradedSheet: View {
    var cards: [OwnedCard]
    var name: (OwnedCard) -> String
    var onSaved: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    struct Draft: Identifiable {
        let id: UUID
        var grader: String
        var grade: String
        var cert: String
    }

    @State private var drafts: [Draft]

    init(cards: [OwnedCard], name: @escaping (OwnedCard) -> String, onSaved: @escaping () -> Void) {
        self.cards = cards
        self.name = name
        self.onSaved = onSaved
        _drafts = State(initialValue: cards.map { card in
            Draft(
                id: card.id,
                // The label it is wearing already names the grader it went to.
                grader: card.graderRaw ?? GradedComps.graderAtGrader(tags: card.tags) ?? "psa",
                grade: card.gradeLabel ?? "",
                cert: card.certNumber ?? ""
            )
        })
    }

    /// Nothing is written for a card he left blank, so a partial return is
    /// one pass: fill in the ones that came back, leave the rest out.
    private var filled: Int {
        drafts.filter { !$0.grade.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach($drafts) { $draft in
                    Section {
                        Picker("Grader", selection: $draft.grader) {
                            ForEach(GradedComps.graders, id: \.self) { Text($0.uppercased()).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        TextField("Grade, e.g. 10 or Pristine 10", text: $draft.grade)
                            .autocorrectionDisabled()
                        TextField("Cert number (optional)", text: $draft.cert)
                            .keyboardType(.numberPad)
                        if let value = value(for: draft) {
                            LabeledContent("Worth at that grade", value: value.asCurrency)
                        }
                    } header: {
                        Text(cards.first { $0.id == draft.id }.map(name) ?? "Card")
                    }
                }
                if cards.count > 1 {
                    Section {
                        EmptyView()
                    } footer: {
                        Text("A card left blank is not changed.")
                    }
                }
            }
            .navigationTitle(cards.count == 1 ? "Mark graded" : "Mark \(cards.count) graded")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(filled == 0)
                }
            }
        }
    }

    /// What he already believes that grade is worth, shown as he types it, so
    /// a grade typed into the wrong row is visible before it is saved.
    private func value(for draft: Draft) -> Int? {
        guard let card = cards.first(where: { $0.id == draft.id }) else { return nil }
        let grade = draft.grade.trimmingCharacters(in: .whitespaces)
        guard !grade.isEmpty else { return nil }
        return GradedComps.value(grader: draft.grader, grade: grade, in: card.effectiveCompCents)
    }

    private func save() {
        let editor = CardTagEditor(context: modelContext)
        for draft in drafts {
            let grade = draft.grade.trimmingCharacters(in: .whitespaces)
            guard !grade.isEmpty, let card = cards.first(where: { $0.id == draft.id }) else { continue }
            let cert = draft.cert.trimmingCharacters(in: .whitespaces)
            card.graderRaw = draft.grader
            card.gradeLabel = grade
            card.certNumber = cert.isEmpty ? nil : cert
            for label in ReservedTag.allAtGrader { editor.remove(label, from: [card]) }
            editor.add(ReservedTag.graded, to: [card])
        }
        try? modelContext.save()
        onSaved()
        dismiss()
    }
}
