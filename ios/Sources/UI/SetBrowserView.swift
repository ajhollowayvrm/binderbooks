import SwiftData
import SwiftUI

/// Every set in the catalog, to be read whether or not he holds a card from it.
///
/// The set picker that already exists narrows a card list; it cannot open a
/// set. This opens one. That is the difference between "which of my cards are
/// from Stellar Crown" and "what is in Stellar Crown", and only the second one
/// is useful before he buys.
///
/// A row carries what he holds from the set, and only when he holds something.
/// A "0 held" on eight hundred sets is noise, and it would also be a lie for
/// the moment before the inventory cache has loaded.
struct SetBrowserView: View {
    @Environment(CatalogController.self) private var catalog
    @Environment(InventoryModel.self) private var inventory
    @Query private var cards: [OwnedCard]

    @State private var sets: [SetSummary] = []
    @State private var query = ""
    @State private var errorMessage: String?

    private var held: [Int: Int] { SetBrowser.heldCounts(cards: cards, hits: inventory.hits) }

    var body: some View {
        List {
            ForEach(SetBrowser.grouped(SetBrowser.visible(sets, query: query)), id: \.category) { group in
                Section(group.category) {
                    ForEach(group.sets) { set in
                        NavigationLink(value: AppRoute.masterSet(set.groupId, set.name)) {
                            row(set)
                        }
                    }
                }
            }
        }
        .navigationTitle("Sets")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Set name or code")
        .overlay {
            if sets.isEmpty {
                if let errorMessage {
                    ContentUnavailableView("The sets did not load", systemImage: "exclamationmark.triangle",
                                           description: Text(errorMessage))
                } else if catalog.isReady {
                    ProgressView()
                } else {
                    ContentUnavailableView("No catalog yet", systemImage: "square.stack",
                                           description: Text("Install the catalog in Settings to read a set."))
                }
            } else if SetBrowser.visible(sets, query: query).isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .task(id: "\(catalog.database?.path ?? "")#\(catalog.version)") {
            await load()
        }
    }

    private func load() async {
        guard let db = catalog.database else { return }
        do {
            sets = try await CatalogSearch(database: db).sets()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The name, then the code, the size, and what he holds. "12 held" and not
    /// "12 of 140": this counts cards and the checklist counts printings, so
    /// the two numbers are allowed to differ and the row must not promise they
    /// agree.
    private func row(_ set: SetSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(set.name)
            Text(caption(set))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func caption(_ set: SetSummary) -> String {
        var parts: [String] = []
        if let abbreviation = set.abbreviation, !abbreviation.isEmpty { parts.append(abbreviation) }
        parts.append(set.productCount == 1 ? "1 product" : "\(set.productCount) products")
        if let count = held[set.groupId], count > 0 { parts.append("\(count) held") }
        return parts.joined(separator: " · ")
    }
}
