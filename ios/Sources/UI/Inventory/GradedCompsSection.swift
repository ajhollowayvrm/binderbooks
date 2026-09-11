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

    static let psa = GradedComps.psaGrades
    static let cgc = GradedComps.cgcGrades

    private var others: [String] {
        let known = Set(Self.psa + Self.cgc)
        return Set(card.gradedCompCents.keys).union(card.fetchedCompCents.keys).filter { !known.contains($0) }.sorted { a, b in
            (GradedComps.gradeNumber(a) ?? 0) == (GradedComps.gradeNumber(b) ?? 0) ? a < b : (GradedComps.gradeNumber(a) ?? 0) > (GradedComps.gradeNumber(b) ?? 0)
        }
    }

    var body: some View {
        Section {
            ForEach(Self.psa, id: \.self) { CompRow(label: $0, card: card) }
            ForEach(Self.cgc, id: \.self) { CompRow(label: $0, card: card) }
            ForEach(others, id: \.self) { CompRow(label: $0, card: card) }
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
            Text("Graded values")
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
        var lines = ["What the card goes for at each grade. A grey figure is PPT's; type over it and yours wins. While the card is at PSA or CGC, its price shows as the range of these."]
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
        _text = State(initialValue: card.gradedCompCents[label].map(Money.fieldText) ?? "")
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
            if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                guard card.gradedCompCents[label] != nil else { return }
                card.gradedCompCents.removeValue(forKey: label)
            } else if let cents = Money.cents(from: newValue), card.gradedCompCents[label] != cents {
                card.gradedCompCents[label] = cents
            } else {
                return
            }
            try? modelContext.save()
        }
    }

    /// PPT's figure sits in the placeholder, so an empty field still reads.
    private var placeholder: String {
        card.fetchedCompCents[label].map(Money.fieldText) ?? "0.00"
    }
}
