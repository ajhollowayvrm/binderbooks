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
    @Environment(InventorySelection.self) private var selection
    @Query(sort: \OwnedCard.acquiredAt, order: .reverse) private var cards: [OwnedCard]
    @State private var allSets: [SetSummary] = []
    @State private var showSetPicker = false
    @State private var showTagFilter = false
    @State private var showMetrics = false
    @State private var recentHits: [SearchHit] = []
    @AppStorage(cardLayoutKey) private var layout: CardLayout = .grid
    @AppStorage(InventorySort.defaultsKey) private var defaultSort: InventorySort = .newest

    private var rows: [InventoryRow] { model.rows(from: cards, query: query) }
    private var tagUses: [TagUse] { model.tagUses(in: cards) }
    private var committed: [OwnedCard] { cards.filter(\.isCommitted) }

    var body: some View {
        let rows = rows
        // Copies of one thing are one line. The rows behind them stay per
        // card, because the sort, the chips, the query, the selection and
        // Metrics all read cards.
        let stacks = InventoryStack.stacks(rows)
        let summary = model.summary(of: rows)
        VStack(spacing: 0) {
            if !catalog.isReady {
                catalogBanner
            }
            HStack(spacing: 0) {
                filterRow
                CardLayoutButton(layout: $layout, accessory: AnyView(sortMenu))
            }
            Divider()
            list(stacks)
        }
        // A new default applies at once. Otherwise a change in Settings shows
        // nothing until the next launch.
        .onChange(of: defaultSort) { _, sort in
            model.sort = sort
        }
        .navigationBarTitleDisplayMode(.inline)
        .inventorySelectionChrome(rows: rows)
        .sheet(isPresented: $showSetPicker) {
            SetPickerSheet(sets: model.sets(in: cards, from: allSets), selected: model.filter.groupId) { groupId in
                model.filter.groupId = groupId
            }
        }
        .sheet(isPresented: $showTagFilter) {
            TagFilterSheet(uses: tagUses, selected: Binding(get: { model.filter.tagKeys }, set: { model.filter.tagKeys = $0 }))
        }
        .sheet(isPresented: $showMetrics) {
            InventoryMetricsSheet(summary: summary, lineCount: stacks.count)
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
            // `CT_NO_PURCHASE=1` turns on the No purchase chip.
            if env["CT_NO_PURCHASE"] == "1" { model.filter.noPurchaseOnly = true }
            // `CT_SLAB_NEWEST="psa|12345678|10"` stamps a cert and a grade on
            // the newest card, because simctl cannot walk the grading sheets.
            // An empty cert field ("cgc||Pristine 10") is the imported ledger's
            // shape: a real grade and no cert number.
            if let spec = env["CT_SLAB_NEWEST"], let newest = committed.first {
                let parts = spec.split(separator: "|", omittingEmptySubsequences: false)
                newest.graderRaw = String(parts.first ?? "psa")
                let cert = parts.count > 1 ? String(parts[1]) : "00000000"
                newest.certNumber = cert.isEmpty ? nil : cert
                newest.gradeLabel = parts.count > 2 && !parts[2].isEmpty ? String(parts[2]) : nil
                try? modelContext.save()
            }
            // `CT_PROJECT_NEWEST="psa|12000,4000,2500"` sends the newest card
            // to that grader on paper and fills its top three comps, so a
            // screenshot shows the projected range.
            // `CT_MARK_GRADED=1` lives in `InventorySelectionChrome`.
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
                    selection.begin(rows.map(\.card.id))
                }
            }
            #endif
        }
    }

    // MARK: - The list

    @ViewBuilder
    private func list(_ stacks: [InventoryStack]) -> some View {
        switch layout {
        case .list:
            List {
                if stacks.isEmpty {
                    emptyState
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(stacks) { stack in
                        SelectableStackRow(stack: stack)
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
                    if stacks.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        SelectableCardGrid(stacks: stacks)
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

    /// Catalog products he opened, newest first. Hidden while a chip or the
    /// search field narrows the page, because it is not part of that answer.
    private var showRecents: Bool { !recentHits.isEmpty && !isFiltered && !selection.isSelecting }

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
                // The cards with no cost to split. Choose a purchase clears them
                // one at a time or as a selection.
                Chip(title: "No purchase", systemImage: "cart.badge.questionmark", isSelected: model.filter.noPurchaseOnly) {
                    model.filter.noPurchaseOnly.toggle()
                }
                // No Sold chip. A card he sold is not inventory, and the ledger
                // holds it on its order.
                if model.filter.isActive {
                    Button("Clear") { model.filter = InventoryFilter() }
                        .font(.subheadline)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    /// A pick here lasts until the app quits. The filled symbol shows that the
    /// page is not in the default order, and the second section makes the
    /// pick the default or goes back to the default.
    private var sortMenu: some View {
        let isTemporary = model.sort != defaultSort
        return Menu {
            Picker("Sort", selection: Binding(get: { model.sort }, set: { model.sort = $0 })) {
                ForEach(InventorySort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            // Here, not in the top bar. The plus took that place.
            Section {
                Button {
                    showMetrics = true
                } label: {
                    Label("Metrics", systemImage: "chart.bar")
                }
                .disabled(rows.isEmpty)
            }
            if isTemporary {
                Section {
                    Button {
                        defaultSort = model.sort
                    } label: {
                        Label("Make default", systemImage: "pin")
                    }
                    Button {
                        model.sort = defaultSort
                    } label: {
                        Label("Back to \(defaultSort.title)", systemImage: "arrow.uturn.backward")
                    }
                }
            }
        } label: {
            Image(systemName: isTemporary ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down")
                .font(.body)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort: \(model.sort.title)")
    }

    private var tagChipTitle: String {
        let keys = model.filter.tagKeys
        if keys.isEmpty { return "Tags" }
        if keys.count == 1, let use = tagUses.first(where: { keys.contains($0.id) }) { return use.label }
        return "\(keys.count) tags"
    }
}
