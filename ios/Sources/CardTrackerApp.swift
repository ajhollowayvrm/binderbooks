import SwiftUI

@main
struct CardTrackerApp: App {
    @State private var catalog = CatalogController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(catalog)
                .task { await catalog.start() }
        }
    }
}
