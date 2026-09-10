import SwiftUI

/// The app shell: a persistent search field with a camera button, above the
/// content. Not a search tab. The scanner arrives in step 4, so the camera
/// button is present but inert.
struct RootView: View {
    @Environment(CatalogController.self) private var catalog
    @State private var search = SearchModel(context: .browsing)
    @State private var recents = RecentlyViewed()

    var body: some View {
        @Bindable var search = search
        NavigationStack {
            VStack(spacing: 0) {
                SearchHeader(query: $search.text, enabled: catalog.isReady)
                Divider()
                content
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        CatalogStatusView()
                    } label: {
                        Label("Catalog", systemImage: "externaldrive")
                    }
                }
            }
        }
        .environment(recents)
        .onAppear(perform: applyDebugQuery)
    }

    @ViewBuilder
    private var content: some View {
        if catalog.isReady {
            SearchResultsView(model: search)
        } else {
            CatalogSetupView()
        }
    }

    /// `SIMCTL_CHILD_CT_SEARCH_QUERY="legendary warriors"` on `simctl launch`
    /// pre-fills the field. Screenshots and manual timing runs need it because
    /// simctl cannot type.
    private func applyDebugQuery() {
        #if DEBUG
        if let query = ProcessInfo.processInfo.environment["CT_SEARCH_QUERY"], search.text.isEmpty {
            search.text = query
        }
        #endif
    }
}

struct SearchHeader: View {
    @Binding var query: String
    var enabled: Bool
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

            Button {
                // Step 4: the scan session.
            } label: {
                Image(systemName: "camera")
                    .font(.title3)
                    .frame(width: 40, height: 36)
            }
            .buttonStyle(.bordered)
            .disabled(true)
            .accessibilityLabel("Scan")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
