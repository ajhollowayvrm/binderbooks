import SwiftData
import SwiftUI

/// What the card sells for at each grade. PPT fills what it has; anything he
/// types wins over it, and clearing his figure shows PPT's again. The
/// imported ledger used bare grades ("10", "9.5") with no grader, so those
/// show under the named rows rather than vanish.
struct GradedCompsSection: View {
    let card: OwnedCard

    @Environment(\.modelContext) private var modelContext
    @State private var fetcher = CompsFetcher()
    @State private var message: String?
    @State private var showAllGrades = false

    static let psa = GradedComps.psaGrades
    static let cgc = GradedComps.cgcGrades

    /// The grade it actually came back at. Once that is known the other
    /// grades are a guess about a question already answered, so the ladder
    /// folds away to the one row that is now true.
    private var knownGrade: String? {
        guard let grader = card.graderRaw, let grade = card.gradeLabel else { return nil }
        return GradedComps.compKey(grader: grader, grade: grade)
    }

    private var others: [String] {
        let known = Set(Self.psa + Self.cgc)
        return Set(card.gradedCompCents.keys).union(card.fetchedCompCents.keys).filter { !known.contains($0) }.sorted { a, b in
            (GradedComps.gradeNumber(a) ?? 0) == (GradedComps.gradeNumber(b) ?? 0) ? a < b : (GradedComps.gradeNumber(a) ?? 0) > (GradedComps.gradeNumber(b) ?? 0)
        }
    }

    var body: some View {
        Section {
            if let knownGrade, !showAllGrades {
                CompRow(label: knownGrade, card: card)
                Button("Show every grade") { showAllGrades = true }
                    .font(.footnote)
            } else {
                ForEach(Self.psa, id: \.self) { CompRow(label: $0, card: card) }
                ForEach(Self.cgc, id: \.self) { CompRow(label: $0, card: card) }
                ForEach(others, id: \.self) { CompRow(label: $0, card: card) }
                if knownGrade != nil {
                    Button("Show only the grade it got") { showAllGrades = false }
                        .font(.footnote)
                }
            }
            Button {
                Task { await fetch() }
            } label: {
                if fetcher.isRunning {
                    Label("Fetching…", systemImage: "arrow.down.circle")
                } else {
                    Label(card.compsFetchedAt == nil ? "Fetch from PPT" : "Fetch again from PPT", systemImage: "arrow.down.circle")
                }
            }
            .disabled(fetcher.isRunning || !card.isIdentified)
        } header: {
            Text(knownGrade == nil ? "Graded values" : "Graded value")
        } footer: {
            Text(footer)
        }
        .alert("Comps", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: {
            Text(message ?? "")
        }
    }

    private var footer: String {
        var lines = knownGrade == nil
            ? ["What the card goes for at each grade. A grey figure is PPT's; type over it and yours wins. While the card is at PSA or CGC, its price shows as the range of these."]
            : ["This card came back \(knownGrade ?? ""), so this is what it is worth and the rest is history. A grey figure is PPT's; type over it and yours wins."]
        if let at = card.compsFetchedAt {
            lines.append("PPT last asked \(at.formatted(date: .abbreviated, time: .shortened)).")
        }
        if !PPTKey.isSet {
            lines.append("Add your PPT key in Settings to fetch.")
        }
        return lines.joined(separator: " ")
    }

    private func fetch() async {
        let report = await fetcher.fetch([card], context: modelContext, client: PPTClient(key: PPTKey.value))
        message = report.summary
    }
}

private struct CompRow: View {
    let label: String
    let card: OwnedCard

    @Environment(\.modelContext) private var modelContext
    @State private var text: String

    init(label: String, card: OwnedCard) {
        self.label = label
        self.card = card
        _text = State(initialValue: Self.find(label, in: card.gradedCompCents).map(Money.fieldText) ?? "")
    }

    /// A grade he typed by hand ("pristine 10") names the same figure as the
    /// row's own spelling, so the lookup folds case the way a tag does. The
    /// write always uses the row's spelling, which settles the key.
    private static func find(_ label: String, in comps: [String: Int]) -> Int? {
        let wanted = TagKey.of(label)
        return comps.first { TagKey.of($0.key) == wanted }?.value
    }

    private static func key(_ label: String, in comps: [String: Int]) -> String? {
        let wanted = TagKey.of(label)
        return comps.keys.first { TagKey.of($0) == wanted }
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField(placeholder, text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .frame(maxWidth: 140)
        }
        .onChange(of: text) { _, newValue in
            let existing = Self.key(label, in: card.gradedCompCents)
            if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let existing else { return }
                card.gradedCompCents.removeValue(forKey: existing)
            } else if let cents = Money.cents(from: newValue), Self.find(label, in: card.gradedCompCents) != cents {
                if let existing, existing != label { card.gradedCompCents.removeValue(forKey: existing) }
                card.gradedCompCents[label] = cents
            } else {
                return
            }
            try? modelContext.save()
        }
    }

    /// PPT's figure sits in the placeholder, so an empty field still reads.
    private var placeholder: String {
        Self.find(label, in: card.fetchedCompCents).map(Money.fieldText) ?? "0.00"
    }
}
