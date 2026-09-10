import SwiftUI

/// The results area under the persistent field. With an empty query and no
/// filter it is the home screen.
struct SearchResultsView: View {
    @Bindable var model: SearchModel
    var onResumeSession: () -> Void = {}

    @Environment(CatalogController.self) private var catalog
    @Environment(RecentlyViewed.self) private var recents
    @State private var showSetPicker = false
    @State private var recentHits: [SearchHit] = []

    var body: some View {
        VStack(spacing: 0) {
            FilterChipRow(model: model, showSetPicker: $showSetPicker)
            Divider()
            content
        }
        .sheet(isPresented: $showSetPicker) {
            SetPickerSheet(sets: model.sets, selected: model.filter.groupId) { groupId in
                model.filter.groupId = groupId
            }
        }
        .task(id: catalog.database?.path) {
            model.database = { [weak catalog] in catalog?.database }
            await model.loadFacets()
            model.schedule()
        }
        .task(id: recents.productIds) {
            await loadRecents()
        }
        .navigationDestination(for: SearchHit.self) { hit in
            ProductDetailView(productId: hit.productId)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isEmptyQuery {
            home
        } else if model.hits.isEmpty {
            if model.isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = model.errorMessage {
                ContentUnavailableView("Search failed", systemImage: "exclamationmark.triangle", description: Text(message))
            } else {
                ContentUnavailableView.search(text: model.text)
            }
        } else {
            results
        }
    }

    private var results: some View {
        List {
            ForEach(model.hits) { hit in
                NavigationLink(value: hit) {
                    ProductRow(hit: hit)
                }
            }
            footer
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Text("\(model.hits.count) results")
            #if DEBUG
            if let duration = model.lastDuration {
                Text("in \(duration.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))")
            }
            #endif
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .listRowSeparator(.hidden)
    }

    /// The empty-query home: the open scan session, cards flagged from recent
    /// scans, and recently viewed products. Step 5 adds recent purchases,
    /// unripped sealed, and cards at grading.
    private var home: some View {
        List {
            HomeInventorySections(onResumeSession: onResumeSession)
            if recentHits.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("Search the catalog", systemImage: "magnifyingglass")
                    } description: {
                        Text("Type a card name, a set, or a collector number like 114/084. Products you open show up here.")
                    }
                    .listRowSeparator(.hidden)
                }
            } else {
                Section {
                    ForEach(recentHits) { hit in
                        NavigationLink(value: hit) {
                            ProductRow(hit: hit)
                        }
                    }
                } header: {
                    HStack {
                        Text("Recently viewed")
                        Spacer()
                        Button("Clear") { recents.clear() }
                            .font(.caption)
                            .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func loadRecents() async {
        guard let db = catalog.database else {
            recentHits = []
            return
        }
        recentHits = (try? await CatalogSearch(database: db).hits(ids: recents.productIds)) ?? []
    }
}
