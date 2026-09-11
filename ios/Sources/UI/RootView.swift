import SwiftData
import SwiftUI

/// The app shell: a persistent search field with a camera button, above the
/// content. Not a search tab, and no tabs at all.
///
/// The content has two states, and `ShellContentView` owns the switch: the
/// inventory page with an empty query, and the two-section result list with a
/// query. Both `navigationDestination` registrations stay here, at the stack
/// root, so a content swap can never break a pushed screen.
struct RootView: View {
    @Environment(CatalogController.self) private var catalog
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<ScanSession> { $0.committedAt == nil }, sort: \ScanSession.startedAt, order: .reverse)
    private var openSessions: [ScanSession]

    @State private var search = SearchModel(context: .browsing)
    @State private var recents = RecentlyViewed()
    @State private var inventory = InventoryModel()
    @State private var launcher = ScannerLauncher()
    @State private var path = NavigationPath()

    var body: some View {
        @Bindable var search = search
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                SearchHeader(query: $search.text, enabled: catalog.isReady, openSessionCount: openSessions.first?.cards.count) {
                    openScanner()
                }
                Divider()
                content
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The inventory owns the leading slot with Metrics, so the
                // ledger sits beside Settings.
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: AppRoute.ledger) {
                        Label("Ledger", systemImage: "list.bullet.rectangle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: AppRoute.settings) {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationDestination(for: SearchHit.self) { hit in
                ProductDetailView(productId: hit.productId)
            }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .settings: SettingsView()
                case .catalogStatus: CatalogStatusView()
                case .ownedCard(let id): OwnedCardDetailView(cardID: id)
                case .ledger:
                    LedgerView(tab: Self.debugLedgerTab, filter: Self.debugLedgerFilter, adding: Self.debugLedgerAdding)
                }
            }
            .navigationDestination(for: LedgerEntry.Kind.self) { kind in
                switch kind {
                case .purchase(let id): PurchaseDetailView(purchaseID: id)
                case .grading(let id): GradingDetailView(submissionID: id)
                case .sale(let id): SaleDetailView(saleID: id)
                case .expense(let id): ExpenseDetailView(expenseID: id)
                }
            }
        }
        .environment(recents)
        .environment(inventory)
        .environment(launcher)
        .fullScreenCover(item: $launcher.session) { session in
            ScanSessionView(session: session) {
                launcher.session = nil
            }
            .environment(catalog)
        }
        .onAppear {
            // Tags replaced the status picker. This copies each card's old
            // status into its reserved label, once.
            StatusTagBackfill.run(modelContext)
            applyDebugQuery()
        }
    }

    private var content: some View {
        ShellContentView(search: search)
    }

    /// Screenshot state for the ledger. Always the default outside DEBUG.
    static var debugLedgerTab: LedgerTab {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CT_OPEN_LEDGER"] == "summary" ? .summary : .activity
        #else
        .activity
        #endif
    }

    static var debugLedgerFilter: LedgerFilter {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["CT_OPEN_LEDGER"] {
        case "in": return .moneyIn
        case "out": return .moneyOut
        default: return .all
        }
        #else
        .all
        #endif
    }

    static var debugLedgerAdding: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CT_OPEN_LEDGER"] == "add"
        #else
        return false
        #endif
    }

    /// Resume the open session if there is one. Otherwise start a new one.
    private func openScanner() {
        if let open = openSessions.first {
            launcher.session = open
        } else {
            let session = ScanSession()
            modelContext.insert(session)
            try? modelContext.save()
            launcher.session = session
        }
    }

    /// The screenshot hooks, because simctl cannot type or tap.
    /// `CT_SEARCH_QUERY="legendary warriors"` pre-fills the field.
    /// `CT_SEARCH_LAYOUT=list` switches every card list to the dense row.
    /// `CT_OPEN_CARD=1` pushes the newest card. `CT_OPEN_SETTINGS=1` pushes
    /// Settings. `CT_OPEN_SCANNER=1` opens the scanner. `CT_OPEN_LEDGER` takes
    /// `1` for the ledger, `in` or `out` for one side of it, `summary` for the
    /// Summary tab, `add` for the add sheet, `sale` for the newest order,
    /// `purchase` for the newest purchase, or `expense` for the newest expense.
    /// `CT_IMPORT_FILE=<path>` merges a collection file, so
    /// a simulator can hold his real books without the file picker.
    /// `CT_OPEN_INVENTORY=1` is deprecated and only returns to the landing
    /// screen.
    /// Screenshots and manual timing runs need them because simctl cannot type.
    private func applyDebugQuery() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let query = env["CT_SEARCH_QUERY"], search.text.isEmpty {
            search.text = query
        }
        // Grid is the default now, so this mostly forces `list`. simctl cannot
        // tap the toggle.
        if let layout = env["CT_SEARCH_LAYOUT"], CardLayout(rawValue: layout) != nil {
            UserDefaults.standard.set(layout, forKey: cardLayoutKey)
        }
        // Deprecated. The inventory is the landing screen, so this only asserts
        // that state. Every existing screenshot command keeps working.
        if env["CT_OPEN_INVENTORY"] == "1" {
            search.text = ""
            path = NavigationPath()
        }
        if env["CT_OPEN_CARD"] == "1" {
            Task {
                while !catalog.isReady { try? await Task.sleep(for: .milliseconds(200)) }
                var descriptor = FetchDescriptor<OwnedCard>(sortBy: [SortDescriptor(\.scannedAt, order: .reverse)])
                descriptor.fetchLimit = 1
                if let card = try? modelContext.fetch(descriptor).first {
                    try? await Task.sleep(for: .milliseconds(300))
                    path.append(AppRoute.ownedCard(card.id))
                }
            }
        }
        // The toolbar button is the only route to Settings and to export.
        if env["CT_OPEN_SETTINGS"] == "1" {
            Task {
                while !catalog.isReady { try? await Task.sleep(for: .milliseconds(200)) }
                path.append(AppRoute.settings)
            }
        }
        if env["CT_OPEN_SCANNER"] == "1" {
            Task {
                while !catalog.isReady { try? await Task.sleep(for: .milliseconds(200)) }
                openScanner()
            }
        }
        // Import without the file picker. Debug only, and it merges, so it can
        // never delete anything.
        if let path = env["CT_IMPORT_FILE"], let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let file = try? CollectionExport.decode(data) {
            try? CollectionExport.apply(file, to: modelContext, mode: .merge)
        }
        if let ledger = env["CT_OPEN_LEDGER"] {
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                path.append(AppRoute.ledger)
                switch ledger {
                case "sale":
                    var d = FetchDescriptor<Sale>(sortBy: [SortDescriptor(\.soldAt, order: .reverse)])
                    d.fetchLimit = 1
                    if let sale = try? modelContext.fetch(d).first { path.append(LedgerEntry.Kind.sale(sale.id)) }
                case "purchase":
                    var d = FetchDescriptor<Purchase>(sortBy: [SortDescriptor(\.date, order: .reverse)])
                    d.fetchLimit = 1
                    if let purchase = try? modelContext.fetch(d).first { path.append(LedgerEntry.Kind.purchase(purchase.id)) }
                case "expense":
                    var d = FetchDescriptor<BusinessExpense>(sortBy: [SortDescriptor(\.date, order: .reverse)])
                    d.fetchLimit = 1
                    if let expense = try? modelContext.fetch(d).first { path.append(LedgerEntry.Kind.expense(expense.id)) }
                default: break
                }
            }
        }
        #endif
    }
}

struct SearchHeader: View {
    @Binding var query: String
    var enabled: Bool
    var openSessionCount: Int?
    var onScan: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search cards and sealed", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($focused)
                    .disabled(!enabled)
                if !query.isEmpty {
                    Button {
                        query = ""
                        focused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))

            Button(action: onScan) {
                Image(systemName: "camera")
                    .font(.title3)
                    .frame(width: 40, height: 36)
                    .overlay(alignment: .topTrailing) {
                        if let count = openSessionCount {
                            Text("\(count)")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.orange, in: Capsule())
                                .foregroundStyle(.white)
                                .offset(x: 6, y: -6)
                        }
                    }
            }
            .buttonStyle(.bordered)
            .disabled(!enabled)
            .accessibilityLabel(openSessionCount == nil ? "Scan" : "Resume scan session")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
