import SwiftData
import SwiftUI

/// End-of-session review. Defaults to the cards that need a look. This editor
/// fixes patterns: select many, then set condition, printing, set, or bulk.
struct ReviewView: View {
    let model: ScanSessionModel
    var onCommitted: () -> Void

    @State private var showAll = false
    @State private var selection: Set<UUID> = []
    @State private var editMode: EditMode = .inactive
    @State private var correcting: OwnedCard?
    @State private var action: BulkAction?
    @State private var showCommit = false
    @State private var showDiscard = false
    @State private var reassignMissed = 0
    @State private var setChoices: [SetSummary] = []
    @State private var tagTarget: TagSheetTarget?
    @Environment(CatalogController.self) private var catalog
    /// Every card in the store, so the tag suggestions match the inventory and
    /// a rename reaches cards outside this session.
    @Query(sort: \OwnedCard.acquiredAt, order: .reverse) private var allCards: [OwnedCard]

    private enum BulkAction: Identifiable {
        case condition, printing, set, delete
        var id: Self { self }
    }

    private var shown: [OwnedCard] {
        showAll ? model.cards : model.cardsNeedingReview
    }

    private var selectedCards: [OwnedCard] {
        model.cards.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterRow
            Divider()
            list
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Commit") { showCommit = true }
                    .disabled(model.cards.isEmpty || model.cards.contains { !$0.isIdentified })
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if editMode.isEditing {
                    Button("Condition") { action = .condition }.disabled(selection.isEmpty)
                    Button("Printing") { action = .printing }.disabled(selection.isEmpty)
                    Button("Set") { action = .set }.disabled(selection.isEmpty)
                    Button("Tag") { tagTarget = TagSheetTarget(cards: selectedCards) }.disabled(selection.isEmpty)
                    Menu("More") {
                        Button("Mark bulk") { model.setBulk(true, for: selectedCards) }
                        Button("Unmark bulk") { model.setBulk(false, for: selectedCards) }
                        Button("Delete", role: .destructive) { action = .delete }
                    }
                    .disabled(selection.isEmpty)
                } else {
                    Button("Discard session", role: .destructive) { showDiscard = true }
                    Spacer()
                    Text("\(model.cards.count) · \(model.sessionTotalCents.asCurrency)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .environment(\.editMode, $editMode)
        .task { await loadSets() }
        .sheet(item: $correcting) { card in
            CardCorrectionView(card: card, model: model)
        }
        .sheet(item: $action) { action in
            bulkSheet(action)
        }
        .sheet(item: $tagTarget) { target in
            TagSheet(target: target, uses: CardTagIndex.uses(in: allCards), allCards: allCards)
        }
        .sheet(isPresented: $showCommit) {
            CommitSheet(model: model) {
                showCommit = false
                onCommitted()
            }
        }
        .confirmationDialog("Discard this session and its \(model.cards.count) cards?", isPresented: $showDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                model.discard()
                onCommitted()
            }
        }
        .alert("Some cards stayed put", isPresented: Binding(get: { reassignMissed > 0 }, set: { if !$0 { reassignMissed = 0 } })) {
            Button("OK") {}
        } message: {
            Text("\(reassignMissed) cards have no matching number in that set.")
        }
    }

    private var filterRow: some View {
        HStack(spacing: 8) {
            Chip(title: "Needs review (\(model.cardsNeedingReview.count))", isSelected: !showAll) { showAll = false }
            Chip(title: "All (\(model.cards.count))", isSelected: showAll) { showAll = true }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var list: some View {
        if shown.isEmpty {
            ContentUnavailableView {
                Label(showAll ? "No cards" : "Nothing to review", systemImage: "checkmark.circle")
            } description: {
                Text(showAll ? "" : "Every match is certain. Commit when ready.")
            }
        } else {
            List(selection: $selection) {
                ForEach(shown) { card in
                    ReviewRow(card: card, hit: model.hit(for: card), marketCents: model.marketCents(for: card))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !editMode.isEditing { correcting = card }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                model.delete([card])
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .tag(card.id)
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private func bulkSheet(_ action: BulkAction) -> some View {
        switch action {
        case .condition:
            ChoiceSheet(title: "Condition for \(selection.count) cards", options: CardCondition.allCases.map(\.rawValue)) { choice in
                model.setCondition(choice, for: selectedCards)
            }
        case .printing:
            let options = Array(Set(selectedCards.flatMap { model.availablePrintings(for: $0) })).sorted()
            ChoiceSheet(title: "Printing for \(selection.count) cards", options: options.isEmpty ? ["Normal", "Reverse Holofoil", "Holofoil"] : options) { choice in
                model.setPrinting(choice, for: selectedCards)
            }
        case .set:
            SetPickerSheet(sets: setChoices, selected: nil) { groupId in
                guard let groupId else { return }
                let cards = selectedCards
                Task {
                    let missed = await model.reassign(cards, toGroup: groupId)
                    reassignMissed = missed.count
                }
            }
        case .delete:
            ChoiceSheet(title: "Delete \(selection.count) cards?", options: ["Delete"], destructive: true) { _ in
                model.delete(selectedCards)
                selection = []
            }
        }
    }

    private func loadSets() async {
        guard setChoices.isEmpty, let db = catalog.database else { return }
        setChoices = (try? await CatalogSearch(database: db).sets()) ?? []
    }
}

private struct ReviewRow: View {
    let card: OwnedCard
    let hit: SearchHit?
    let marketCents: Int?

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                ProductThumbnail(urlString: hit?.imageUrl, isSealed: false)
                    .frame(width: 40, height: 56)
                ConfidenceMarker(confidence: card.matchConfidence, identified: card.isIdentified, isBulk: card.isBulk)
                    .offset(x: 4, y: -4)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(hit?.name ?? card.ocrName ?? (card.certNumber.map { "Slab \($0)" } ?? "Unknown"))
                    .lineLimit(1)
                if let hit {
                    Text(hit.setName).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let number = hit?.number { Text(number).monospacedDigit() }
                    if !card.printing.isEmpty { Text(card.printing) }
                    Text(CardCondition(rawValue: card.condition)?.short ?? card.condition)
                    if card.isBulk { Text("Bulk") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(marketCents?.asCurrency ?? "—")
                .font(.body.monospacedDigit())
        }
    }
}

/// A one-tap chip sheet. Replaces a picker.
struct ChoiceSheet: View {
    var title: String
    var options: [String]
    var destructive = false
    var onChoose: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(options, id: \.self) { option in
                Button(role: destructive ? .destructive : nil) {
                    onChoose(option)
                    dismiss()
                } label: {
                    Text(option)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
