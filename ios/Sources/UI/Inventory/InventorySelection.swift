import SwiftData
import SwiftUI

/// Which owned cards he has ticked, and whether he is ticking.
///
/// `RootView` owns it, so the selection lives through a keystroke:
/// the inventory page and the search results page both select from it, and
/// typing in the search field switches between them.
@MainActor
@Observable
final class InventorySelection {
    var isSelecting = false
    var ids: Set<UUID> = []
    /// When the long press started selection. See `toggle`.
    private var startedAt: Date?

    /// A long press lands here. One animation covers the Done button, the
    /// bars, and every mark on the cards, so selection mode arrives as one
    /// movement instead of three pops.
    func begin(_ ids: [UUID]) {
        guard !isSelecting else { return }
        startedAt = Date()
        withAnimation(.snappy(duration: 0.28)) {
            isSelecting = true
            self.ids = Set(ids)
        }
    }

    /// One line, every copy on it. A partly ticked line completes instead of
    /// clearing, because a half-selected stack is not a state he asked for.
    ///
    /// The long press turns the card under his finger into a toggle button
    /// while the finger is still down. Lifting it then taps that button and
    /// unticks the card he pressed, on some presses and not others. A toggle
    /// in the first half second of selection is that lift, so it is ignored.
    func toggle(_ ids: [UUID]) {
        if let startedAt, Date().timeIntervalSince(startedAt) < 0.5 { return }
        withAnimation(.snappy(duration: 0.15)) {
            if ids.allSatisfy(self.ids.contains) {
                self.ids.subtract(ids)
            } else {
                self.ids.formUnion(ids)
            }
        }
    }

    func selectAll(_ ids: [UUID]) {
        startedAt = nil
        self.ids = Set(ids)
    }

    func end() {
        startedAt = nil
        withAnimation(.snappy(duration: 0.28)) {
            isSelecting = false
            ids = []
        }
    }

    /// The ticked cards among `rows`. Through the live rows, so an id left
    /// stale by a delete or a filter resolves to nothing instead of crashing.
    func cards(in rows: [InventoryRow]) -> [OwnedCard] {
        rows.map(\.card).filter { ids.contains($0.id) }
    }
}

/// One list line that pushes its card, or, while selecting, ticks it. A long
/// press starts selection with the line already ticked.
struct SelectableStackRow: View {
    var stack: InventoryStack

    @Environment(InventorySelection.self) private var selection

    var body: some View {
        // A stacked line is ticked when every copy is, and ticking it takes
        // all of them: the line is the nine packs, not one of them.
        let ticked = stack.cardIds.allSatisfy(selection.ids.contains)
        if selection.isSelecting {
            Button {
                selection.toggle(stack.cardIds)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(ticked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .contentTransition(.symbolEffect(.replace))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    OwnedCardRow(row: stack.lead, stack: stack)
                }
            }
            .buttonStyle(.plain)
        } else {
            HStack {
                OwnedCardRow(row: stack.lead, stack: stack)
                // The chevron a `NavigationLink` drew. See `pushOrSelect`.
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .pushOrSelect(stack) { selection.begin(stack.cardIds) }
        }
    }
}

/// The grid of owned cells, wired to the shared selection.
struct SelectableCardGrid: View {
    var stacks: [InventoryStack]

    @Environment(InventorySelection.self) private var selection

    var body: some View {
        OwnedCardGrid(
            stacks: stacks,
            isSelecting: selection.isSelecting,
            selection: selection.ids,
            onToggle: selection.toggle,
            onLongPress: selection.begin
        )
    }
}

/// The bars and the sheets of selection mode: Done and the count at the top,
/// the actions at the bottom. The inventory page and the search results page
/// both wear it.
///
/// The count and Select all sit in the top bar. The bottom bar holds only the
/// actions and Delete, because with the count and Select all too it ran off
/// the side of the screen.
private struct InventorySelectionChrome: ViewModifier {
    /// The cards on screen. Select all takes these, and only these can act.
    var rows: [InventoryRow]

    @Environment(InventoryModel.self) private var model
    @Environment(InventorySelection.self) private var selection
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \OwnedCard.acquiredAt, order: .reverse) private var cards: [OwnedCard]
    @State private var tagTarget: TagSheetTarget?
    @State private var gradeTarget: TagSheetTarget?
    @State private var markGradedTarget: TagSheetTarget?
    @State private var sellTarget: TagSheetTarget?
    @State private var compsTarget: TagSheetTarget?
    @State private var listTarget: TagSheetTarget?
    @State private var purchaseTarget: TagSheetTarget?
    @State private var ripTarget: TagSheetTarget?
    @State private var deleteTarget: TagSheetTarget?
    @State private var fetcher = CompsFetcher()
    @State private var compsMessage: String?

    private var tagUses: [TagUse] { model.tagUses(in: cards) }
    private var committed: [OwnedCard] { cards.filter(\.isCommitted) }
    private var selected: [OwnedCard] { selection.cards(in: rows) }

    func body(content: Content) -> some View {
        content
            .toolbar {
                // Only while selecting. A long press on a card is how selection
                // starts, so a permanent Select button is a second door to the
                // same room.
                if selection.isSelecting {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Select all") { selection.selectAll(rows.map(\.card.id)) }
                            .disabled(selected.count == rows.count)
                    }
                    ToolbarItem(placement: .principal) {
                        Text(fetcher.isRunning ? "comps \(fetcher.done)/\(fetcher.total)" : "\(selected.count) selected")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { selection.end() }
                            .transition(.opacity.combined(with: .scale(scale: 0.7)))
                    }
                }
                if selection.isSelecting {
                    ToolbarItemGroup(placement: .bottomBar) {
                        actions
                    }
                    // Apart from the others, so a thumb that reaches for Sell
                    // does not land on it.
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        Button(role: .destructive) {
                            deleteTarget = TagSheetTarget(cards: selected)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(selected.isEmpty)
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: selection.isSelecting)
            .sheet(item: $tagTarget) { target in
                TagSheet(target: target, uses: tagUses, allCards: committed) {
                    model.invalidateHaystacks()
                }
            }
            .sheet(item: $gradeTarget) { target in
                SendToGraderSheet(cards: target.cards) {
                    model.invalidateHaystacks()
                    selection.end()
                }
            }
            .sheet(item: $markGradedTarget) { target in
                MarkGradedSheet(cards: target.cards, name: { $0.displayName(model.hits[$0.productId]) ?? "Card" }) {
                    model.invalidateHaystacks()
                    selection.end()
                }
            }
            .sheet(item: $sellTarget) { target in
                SellSheet(cards: target.cards, name: { $0.displayName(model.hits[$0.productId]) ?? "" }) {
                    model.invalidateHaystacks()
                    selection.end()
                }
            }
            .sheet(item: $listTarget) { target in
                TCGplayerExportSheet(preselected: Set(target.cards.map(\.id)))
            }
            .sheet(item: $purchaseTarget) { target in
                ChoosePurchaseSheet(cards: target.cards) {
                    model.invalidateHaystacks()
                    selection.end()
                }
            }
            .ripSheet($ripTarget) {
                model.invalidateHaystacks()
                selection.end()
            }
            .confirmationDialog(
                deleteTarget.map { $0.cards.count == 1 ? "Delete 1 card from inventory?" : "Delete \($0.cards.count) cards from inventory?" } ?? "",
                isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let target = deleteTarget { delete(target.cards) }
                }
            } message: {
                Text("This cannot be undone. A purchase keeps its cost.")
            }
            // The count and the cost show before anything is spent. A run over
            // three hundred cards is most of a day's credits.
            .confirmationDialog(
                compsTarget.map { "Fetch comps for \($0.cards.count) cards? About \(CompsFetcher.creditEstimate(for: $0.cards)) PPT credits." } ?? "",
                isPresented: Binding(get: { compsTarget != nil }, set: { if !$0 { compsTarget = nil } }),
                titleVisibility: .visible
            ) {
                Button("Fetch") {
                    if let target = compsTarget { Task { await fetchComps(target.cards) } }
                }
            }
            .alert("Comps", isPresented: Binding(get: { compsMessage != nil }, set: { if !$0 { compsMessage = nil } })) {
                Button("OK") {}
            } message: {
                Text(compsMessage ?? "")
            }
            .onAppear {
                #if DEBUG
                // `CT_MARK_GRADED=1` opens the sheet on the newest card, because
                // simctl cannot reach a button inside a pushed screen.
                if ProcessInfo.processInfo.environment["CT_MARK_GRADED"] == "1", let newest = committed.first {
                    markGradedTarget = TagSheetTarget(cards: [newest])
                }
                #endif
            }
    }

    @ViewBuilder
    private var actions: some View {
        let selected = selected
        // A menu, not a sheet, because the long press that starts selection
        // replaced the row's tag menu. The labels he uses most stay one tap
        // away, for one card or for thirty.
        Menu("Tag") {
            ForEach(tagUses.prefix(5)) { use in
                Button {
                    CardTagEditor(context: modelContext).toggle(use.label, on: selected)
                    model.invalidateHaystacks()
                } label: {
                    Label(use.label, systemImage: mark(for: use, in: selected))
                }
            }
            if !tagUses.isEmpty { Divider() }
            Button {
                tagTarget = TagSheetTarget(cards: selected)
            } label: {
                Label("Tag…", systemImage: "tag")
            }
        }
        .disabled(selected.isEmpty)
        // Two different events: money going out to a grader, and cards coming
        // back at a grade. The imported charges name no cards, so the second
        // is the only way those 40 cards ever get their grade.
        Menu("Grade") {
            Button {
                gradeTarget = TagSheetTarget(cards: selected)
            } label: {
                Label("Send to grader…", systemImage: "shippingbox")
            }
            .disabled(selected.contains { $0.isSlabbed })
            Button {
                markGradedTarget = TagSheetTarget(cards: selected)
            } label: {
                Label("Mark as graded…", systemImage: "seal")
            }
        }
        .disabled(selected.isEmpty)
        Button("Sell") { sellTarget = TagSheetTarget(cards: selected) }
            .disabled(selected.isEmpty || selected.contains { CardTagIndex.has(ReservedTag.sold, on: $0) })
        Menu {
            Button {
                compsTarget = TagSheetTarget(cards: selected)
            } label: {
                Label("Fetch comps from PPT", systemImage: "arrow.down.circle")
            }
            .disabled(!PPTKey.isSet)
            Button {
                listTarget = TagSheetTarget(cards: selected)
            } label: {
                Label("List on TCGplayer…", systemImage: "tablecells")
            }
            Button {
                purchaseTarget = TagSheetTarget(cards: selected)
            } label: {
                Label("Choose a purchase…", systemImage: "cart")
            }
            // Only sealed packs rip. Packs from several purchases rip as one:
            // the pulls share their cost.
            Button {
                ripTarget = TagSheetTarget(cards: selected)
            } label: {
                Label("Rip…", systemImage: "shippingbox.and.arrow.backward")
            }
            .disabled(!selected.allSatisfy(\.isSealedSelf))
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(selected.isEmpty || fetcher.isRunning)
    }

    /// All, some, or none of the selected cards carry the label.
    private func mark(for use: TagUse, in cards: [OwnedCard]) -> String {
        let held = cards.filter { CardTagIndex.has(use.label, on: $0) }.count
        if held == 0 { return "tag" }
        if held == cards.count { return "checkmark" }
        return "minus"
    }

    /// The same as Delete card on one card's screen, for each one.
    private func delete(_ cards: [OwnedCard]) {
        for card in cards { modelContext.delete(card) }
        try? modelContext.save()
        model.invalidateHaystacks()
        selection.end()
    }

    private func fetchComps(_ cards: [OwnedCard]) async {
        let report = await fetcher.fetch(cards, context: modelContext, client: PPTClient(key: PPTKey.value)) { model.hits[$0.productId]?.categoryId }
        compsMessage = report.summary
        selection.end()
    }
}

extension View {
    /// Selection mode's bars and sheets, over the owned cards in `rows`.
    func inventorySelectionChrome(rows: [InventoryRow]) -> some View {
        modifier(InventorySelectionChrome(rows: rows))
    }
}
