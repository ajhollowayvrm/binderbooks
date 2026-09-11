import SwiftData
import SwiftUI

/// The app's landing screen. Owned cards with market value, basis, and the
/// difference where the basis is real. Filters are chips. Graded cards render
/// as slabs. The persistent search field sits above this view and passes its
/// text down as `query`.
struct InventoryView: View {
    var query: String = ""

    @Environment(CatalogController.self) private var catalog
    @Environment(InventoryModel.self) private var model
    @Environment(RecentlyViewed.self) private var recents
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \OwnedCard.acquiredAt, order: .reverse) private var cards: [OwnedCard]
    @State private var allSets: [SetSummary] = []
    @State private var showSetPicker = false
    @State private var showTagFilter = false
    @State private var showMetrics = false
    @State private var tagTarget: TagSheetTarget?
    @State private var gradeTarget: TagSheetTarget?
    @State private var sellTarget: TagSheetTarget?
    @State private var compsTarget: TagSheetTarget?
    @State private var fetcher = CompsFetcher()
    @State private var compsMessage: String?
    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var recentHits: [SearchHit] = []
    @AppStorage(cardLayoutKey) private var layout: CardLayout = .grid

    private var rows: [InventoryRow] { model.rows(from: cards, query: query) }
    private var tagUses: [TagUse] { model.tagUses(in: cards) }
    private var committed: [OwnedCard] { cards.filter(\.isCommitted) }

    /// Filters through the live rows, so an id left stale by a delete or a
    /// filter change resolves to nothing instead of crashing.
    private func selectedCards(_ rows: [InventoryRow]) -> [OwnedCard] {
        rows.map(\.card).filter { selection.contains($0.id) }
    }

    var body: some View {
        let rows = rows
        let summary = model.summary(of: rows)
        VStack(spacing: 0) {
            if !catalog.isReady {
                catalogBanner
            }
            HStack(spacing: 0) {
                filterRow
                CardLayoutButton(layout: $layout)
            }
            Divider()
            list(rows)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Metrics") { showMetrics = true }
                    .disabled(rows.isEmpty)
            }
            // Only while selecting. A long press on a card is how selection
            // starts, so a permanent Select button is a second door to the
            // same room.
            if isSelecting {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { endSelection() }
                        .transition(.opacity.combined(with: .scale(scale: 0.7)))
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if isSelecting {
                    // A menu, not a sheet, because the long press that starts
                    // selection replaced the row's tag menu. The labels he uses
                    // most stay one tap away, for one card or for thirty.
                    Menu("Tag") {
                        ForEach(tagUses.prefix(5)) { use in
                            Button {
                                CardTagEditor(context: modelContext).toggle(use.label, on: selectedCards(rows))
                                model.invalidateHaystacks()
                            } label: {
                                Label(use.label, systemImage: mark(for: use, in: rows))
                            }
                        }
                        if !tagUses.isEmpty { Divider() }
                        Button {
                            tagTarget = TagSheetTarget(cards: selectedCards(rows))
                        } label: {
                            Label("Tag…", systemImage: "tag")
                        }
                    }
                    .disabled(selection.isEmpty)
                    // Raw cards only. A slab is already graded.
                    Button("Grade") { gradeTarget = TagSheetTarget(cards: selectedCards(rows)) }
                        .disabled(selection.isEmpty || selectedCards(rows).contains { $0.certNumber != nil })
                    Button("Sell") { sellTarget = TagSheetTarget(cards: selectedCards(rows)) }
                        .disabled(selection.isEmpty || selectedCards(rows).contains { CardTagIndex.has(ReservedTag.sold, on: $0) })
                    Menu {
                        Button {
                            compsTarget = TagSheetTarget(cards: selectedCards(rows))
                        } label: {
                            Label("Fetch comps from PPT", systemImage: "arrow.down.circle")
                        }
                        .disabled(!PPTKey.isSet)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(selection.isEmpty || fetcher.isRunning)
                    Spacer()
                    Text(fetcher.isRunning ? "comps \(fetcher.done)/\(fetcher.total)" : "\(selection.count) selected")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        // The bottom bar squeezes the middle item first, and
                        // "3 se…" is not a count.
                        .fixedSize()
                    Spacer()
                    Button("Select all") { selection = Set(rows.map(\.card.id)) }
                        .disabled(selection.count == rows.count)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: isSelecting)
        .sheet(isPresented: $showSetPicker) {
            SetPickerSheet(sets: model.sets(in: cards, from: allSets), selected: model.filter.groupId) { groupId in
                model.filter.groupId = groupId
            }
        }
        .sheet(isPresented: $showTagFilter) {
            TagFilterSheet(uses: tagUses, selected: Binding(get: { model.filter.tagKeys }, set: { model.filter.tagKeys = $0 }))
        }
        .sheet(isPresented: $showMetrics) {
            InventoryMetricsSheet(summary: summary, rowCount: rows.count)
        }
        .sheet(item: $tagTarget) { target in
            TagSheet(target: target, uses: tagUses, allCards: committed) {
                model.invalidateHaystacks()
            }
        }
        .sheet(item: $gradeTarget) { target in
            SendToGraderSheet(cards: target.cards) {
                model.invalidateHaystacks()
                endSelection()
            }
        }
        .sheet(item: $sellTarget) { target in
            SellSheet(cards: target.cards, name: { model.hits[$0.productId]?.name ?? $0.ocrName ?? "" }) {
                model.invalidateHaystacks()
                endSelection()
            }
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
        // `ShellContentView` owns the hit and price caches, because a query
        // needs them even when this page never appeared.
        .task(id: catalog.database?.path) {
            if let db = catalog.database, allSets.isEmpty {
                allSets = (try? await CatalogSearch(database: db).sets()) ?? []
            }
        }
        .task(id: recents.productIds) {
            await loadRecents()
        }
        .onAppear {
            #if DEBUG
            // `CT_OPEN_METRICS=1` opens the sheet, because simctl cannot tap
            // the button.
            let env = ProcessInfo.processInfo.environment
            if env["CT_OPEN_METRICS"] == "1" { showMetrics = true }
            // `CT_SLAB_NEWEST="psa|12345678|10"` stamps a cert and a grade on
            // the newest card, because simctl cannot walk the grading sheets.
            if let spec = env["CT_SLAB_NEWEST"], let newest = committed.first {
                let parts = spec.split(separator: "|")
                newest.graderRaw = String(parts.first ?? "psa")
                newest.certNumber = parts.count > 1 ? String(parts[1]) : "00000000"
                newest.gradeLabel = parts.count > 2 ? String(parts[2]) : nil
                try? modelContext.save()
            }
            // `CT_PROJECT_NEWEST="psa|12000,4000,2500"` sends the newest card
            // to that grader on paper and fills its top three comps, so a
            // screenshot shows the projected range.
            if let spec = env["CT_PROJECT_NEWEST"], let newest = committed.first {
                let parts = spec.split(separator: "|")
                let grader = String(parts.first ?? "psa")
                let grades = grader == "cgc" ? GradedComps.cgcGrades : GradedComps.psaGrades
                let cents = parts.count > 1 ? parts[1].split(separator: ",").compactMap { Int($0) } : []
                for (grade, value) in zip(grades, cents) { newest.gradedCompCents[grade] = value }
                CardTagEditor(context: modelContext).add(ReservedTag.atGrader(grader), to: [newest])
            }
            // `CT_SELECT_ALL=1` enters selection with every row ticked, because
            // simctl cannot long press.
            if env["CT_SELECT_ALL"] == "1" {
                // Late and animated on purpose: a screen recording then catches
                // the same transition a long press produces.
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation(.snappy(duration: 0.28)) {
                        isSelecting = true
                        selection = Set(rows.map(\.card.id))
                    }
                }
            }
            #endif
        }
    }

    // MARK: - The list

    @ViewBuilder
    private func list(_ rows: [InventoryRow]) -> some View {
        switch layout {
        case .list:
            List {
                if rows.isEmpty {
                    emptyState
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(rows) { row in
                        cardRow(row)
                    }
                }
                recentlyViewedRows
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
        case .grid:
            // A grid cannot live in a `List`: a `NavigationLink` inside a list
            // row draws a chevron on every cell.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        OwnedCardGrid(
                            rows: rows,
                            isSelecting: isSelecting,
                            selection: selection,
                            onToggle: toggleSelection,
                            onLongPress: beginSelection
                        )
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                    }
                    recentlyViewedGrid
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(isFiltered ? "No cards match" : "No inventory yet", systemImage: "tray")
        } description: {
            Text(isFiltered ? "Clear a filter." : "Commit a scan session and the cards land here.")
        }
    }

    @ViewBuilder
    private func cardRow(_ row: InventoryRow) -> some View {
        if isSelecting {
            Button {
                toggleSelection(row.card.id)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selection.contains(row.card.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selection.contains(row.card.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .contentTransition(.symbolEffect(.replace))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    OwnedCardRow(row: row)
                }
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: AppRoute.ownedCard(row.card.id)) {
                OwnedCardRow(row: row)
            }
            // A simultaneous gesture, so the long press cannot swallow the tap
            // that pushes the card.
            .simultaneousGesture(longPress(row.card.id))
        }
    }

    /// Selection starts on a long press, with that card already ticked.
    private func longPress(_ id: UUID) -> some Gesture {
        LongPressGesture(minimumDuration: 0.4).onEnded { _ in
            beginSelection(id)
        }
    }

    /// All, some, or none of the selected cards carry the label.
    private func mark(for use: TagUse, in rows: [InventoryRow]) -> String {
        let cards = selectedCards(rows)
        let held = cards.filter { CardTagIndex.has(use.label, on: $0) }.count
        if held == 0 { return "tag" }
        if held == cards.count { return "checkmark" }
        return "minus"
    }

    /// Catalog products he opened, newest first. Hidden while a chip or the
    /// search field narrows the page, because it is not part of that answer.
    private var showRecents: Bool { !recentHits.isEmpty && !isFiltered && !isSelecting }

    @ViewBuilder
    private var recentlyViewedRows: some View {
        if showRecents {
            Section {
                ForEach(recentHits) { hit in
                    NavigationLink(value: hit) {
                        ProductRow(hit: hit)
                    }
                }
            } header: {
                recentsHeader.textCase(nil)
            }
        }
    }

    @ViewBuilder
    private var recentlyViewedGrid: some View {
        if showRecents {
            CardSectionHeader(title: "Recently viewed", trailing: AnyView(
                Button("Clear") { recents.clear() }.font(.caption)
            ))
            ProductCardGrid(hits: recentHits)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
    }

    private var recentsHeader: some View {
        HStack {
            Text("Recently viewed")
            Spacer()
            Button("Clear") { recents.clear() }
                .font(.caption)
        }
    }

    private var isFiltered: Bool { model.filter.isActive || !query.isEmpty }

    private func toggleSelection(_ id: UUID) {
        withAnimation(.snappy(duration: 0.15)) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        }
    }

    /// The long press lands here. One animation covers the Done button, the
    /// bottom bar, and every mark on the cards, so selection mode arrives as
    /// one movement instead of three pops.
    private func beginSelection(_ id: UUID) {
        guard !isSelecting else { return }
        withAnimation(.snappy(duration: 0.28)) {
            isSelecting = true
            selection = [id]
        }
    }

    private func endSelection() {
        withAnimation(.snappy(duration: 0.28)) {
            isSelecting = false
            selection = []
        }
    }

    private func fetchComps(_ cards: [OwnedCard]) async {
        let report = await fetcher.fetch(cards, context: modelContext, client: PPTClient(key: PPTKey.value))
        compsMessage = report.summary
        endSelection()
    }

    private func loadRecents() async {
        guard let db = catalog.database else {
            recentHits = []
            return
        }
        recentHits = (try? await CatalogSearch(database: db).hits(ids: recents.productIds)) ?? []
    }

    // MARK: - Header

    private var catalogBanner: some View {
        NavigationLink(value: AppRoute.catalogStatus) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                Text("Catalog not installed. Prices and names are hidden.")
                    .font(.footnote)
                Spacer()
                Text("Details")
                    .font(.footnote.weight(.semibold))
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.yellow.opacity(0.18))
        }
        .buttonStyle(.plain)
    }

    /// Three chips, and that is deliberate. Tags carry what the status chips
    /// carried, and he narrows by label far more than by anything else. Sold
    /// gets its own chip because a sold card is hidden, not filtered.
    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Chip(title: tagChipTitle, systemImage: "tag", isSelected: !model.filter.tagKeys.isEmpty) {
                    showTagFilter = true
                }
                if let set = allSets.first(where: { $0.groupId == model.filter.groupId }) {
                    Chip(title: set.name, systemImage: "xmark", isSelected: true) { model.filter.groupId = nil }
                } else {
                    Chip(title: "Set", systemImage: "square.stack", isSelected: false) { showSetPicker = true }
                }
                // Sold cards left inventory. This is the one door back to them.
                Chip(title: "Sold", systemImage: model.filter.showSold ? "checkmark" : "bag", isSelected: model.filter.showSold) {
                    model.filter.showSold.toggle()
                }
                if model.filter.isActive {
                    Button("Clear") { model.filter = InventoryFilter() }
                        .font(.subheadline)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private var tagChipTitle: String {
        let keys = model.filter.tagKeys
        if keys.isEmpty { return "Tags" }
        if keys.count == 1, let use = tagUses.first(where: { keys.contains($0.id) }) { return use.label }
        return "\(keys.count) tags"
    }
}
