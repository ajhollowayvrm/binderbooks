import SwiftData
import SwiftUI

@main
struct CardTrackerApp: App {
    @State private var catalog = CatalogController()
    private let container: ModelContainer

    init() {
        do {
            container = try CollectionStore.container()
        } catch {
            // The collection store is the irreplaceable half of the app. Without
            // it nothing else is safe to run.
            fatalError("Could not open the collection store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(catalog)
                .task { await catalog.start() }
        }
        .modelContainer(container)
    }
}
