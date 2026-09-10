import SwiftData
import SwiftUI

/// The area under the persistent search field. Two states, and the query
/// decides which one.
///
/// The inventory is the landing screen, so it is never pushed. This view
/// replaces the navigation stack's root only, which is why a pushed card or
/// product detail survives a keystroke.
struct ShellContentView: View {
    var search: SearchModel

    @Environment(CatalogController.self) private var catalog
    @Environment(InventoryModel.self) private var inventory
    @Query private var committed: [OwnedCard]

    init(search: SearchModel) {
        self.search = search
        // A card is inventory once its session commits, or when it never came
        // from a scan. `#Predicate` cannot read the computed `isCommitted`.
        _committed = Query(filter: #Predicate<OwnedCard> { $0.scanSession == nil || $0.scanSession?.committedAt != nil })
    }

    var body: some View {
        content
            // Both states read the inventory caches, so the wiring lives here.
            // A launch straight into a query must still answer with art and
            // prices for the cards he owns.
            .task(id: catalog.database?.path) {
                inventory.database = { [weak catalog] in catalog?.database }
                if inventory.catalogPath != catalog.database?.path {
                    inventory.invalidate()
                    inventory.catalogPath = catalog.database?.path
                }
                await inventory.load(for: committed)
            }
            .task(id: committed.count) {
                await inventory.load(for: committed)
            }
    }

    @ViewBuilder
    private var content: some View {
        // Order matters. A query must never fall back to the setup screen.
        if !search.isEmptyQuery {
            SearchResultsView(model: search)
        } else if !catalog.isReady, committed.isEmpty {
            CatalogSetupView()
        } else {
            InventoryView(query: search.text)
        }
    }
}
