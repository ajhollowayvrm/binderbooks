import SwiftData
import SwiftUI

/// The app shell: a persistent search field with a camera button, above the
/// content. Not a search tab.
struct RootView: View {
    @Environment(CatalogController.self) private var catalog
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<ScanSession> { $0.committedAt == nil }, sort: \ScanSession.startedAt, order: .reverse)
    private var openSessions: [ScanSession]

    @State private var search = SearchModel(context: .browsing)
    @State private var recents = RecentlyViewed()
    @State private var activeSession: ScanSession?
    @State private var pushInventory = false

    var body: some View {
        @Bindable var search = search
        NavigationStack {
            VStack(spacing: 0) {
                SearchHeader(query: $search.text, enabled: catalog.isReady, openSessionCount: openSessions.first?.cards.count) {
                    openScanner()
                }
                Divider()
                content
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        InventoryView()
                    } label: {
                        Label("Inventory", systemImage: "tray.full")
                    }
                    .disabled(!catalog.isReady)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationDestination(for: SearchHit.self) { hit in
                ProductDetailView(productId: hit.productId)
            }
            .navigationDestination(isPresented: $pushInventory) {
                InventoryView()
            }
        }
        .environment(recents)
        .fullScreenCover(item: $activeSession) { session in
            ScanSessionView(session: session) {
                activeSession = nil
            }
            .environment(catalog)
        }
        .onAppear(perform: applyDebugQuery)
    }

    @ViewBuilder
    private var content: some View {
        if catalog.isReady {
            SearchResultsView(model: search, onResumeSession: openScanner)
        } else {
            CatalogSetupView()
        }
    }

    /// Resume the open session if there is one. Otherwise start a new one.
    private func openScanner() {
        if let open = openSessions.first {
            activeSession = open
        } else {
            let session = ScanSession()
            modelContext.insert(session)
            try? modelContext.save()
            activeSession = session
        }
    }

    /// `SIMCTL_CHILD_CT_SEARCH_QUERY="legendary warriors"` on `simctl launch`
    /// pre-fills the field; `SIMCTL_CHILD_CT_OPEN_SCANNER=1` opens the scanner.
    /// Screenshots and manual timing runs need them because simctl cannot type.
    private func applyDebugQuery() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let query = env["CT_SEARCH_QUERY"], search.text.isEmpty {
            search.text = query
        }
        if env["CT_OPEN_INVENTORY"] == "1" {
            Task {
                while !catalog.isReady { try? await Task.sleep(for: .milliseconds(200)) }
                pushInventory = true
            }
        }
        if env["CT_OPEN_SCANNER"] == "1" {
            Task {
                while !catalog.isReady { try? await Task.sleep(for: .milliseconds(200)) }
                openScanner()
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
