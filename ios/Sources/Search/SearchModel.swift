import Foundation
import Observation

/// Drives one search field: debounce, cancellation, and the result list.
@MainActor
@Observable
final class SearchModel {
    var text = "" {
        didSet { if text != oldValue { schedule() } }
    }
    var filter = SearchFilter() {
        didSet { if filter != oldValue { schedule() } }
    }
    let context: SearchContext

    private(set) var hits: [SearchHit] = []
    private(set) var isSearching = false
    private(set) var lastDuration: Duration?
    private(set) var categories: [CategorySummary] = []
    private(set) var sets: [SetSummary] = []
    private(set) var errorMessage: String?

    /// Supplied by the owner. Nil while the catalog swaps.
    var database: @MainActor () -> CatalogDatabase? = { nil }

    private var task: Task<Void, Never>?
    private var loadedCatalogPath: String?

    static let debounce: Duration = .milliseconds(150)

    init(context: SearchContext) {
        self.context = context
    }

    var isEmptyQuery: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty && !filter.isActive }

    var selectedSet: SetSummary? {
        guard let groupId = filter.groupId else { return nil }
        return sets.first { $0.groupId == groupId }
    }

    /// Loads the chip data once per installed catalog.
    func loadFacets() async {
        guard let db = database(), db.path != loadedCatalogPath else { return }
        loadedCatalogPath = db.path
        let search = CatalogSearch(database: db)
        do {
            categories = try await search.categories()
            sets = try await search.sets()
        } catch {
            errorMessage = error.localizedDescription
        }
        // A set from the previous catalog may no longer exist.
        if let groupId = filter.groupId, !sets.contains(where: { $0.groupId == groupId }) {
            filter.groupId = nil
        }
    }

    func schedule() {
        task?.cancel()
        let request = SearchRequest(text: text, context: context, filter: filter)
        if request.trimmed.isEmpty && !filter.isActive {
            hits = []
            isSearching = false
            return
        }
        isSearching = true
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            await self.run(request)
        }
    }

    private func run(_ request: SearchRequest) async {
        guard let db = database() else {
            hits = []
            isSearching = false
            return
        }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let result = try await CatalogSearch(database: db).search(request)
            guard !Task.isCancelled else { return }
            hits = result
            lastDuration = clock.now - start
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
        isSearching = false
    }

    func toggleCategory(_ id: Int) {
        if filter.categoryIds.contains(id) {
            filter.categoryIds.remove(id)
        } else {
            filter.categoryIds.insert(id)
        }
    }

    func clearFilters() {
        filter = SearchFilter()
    }
}
