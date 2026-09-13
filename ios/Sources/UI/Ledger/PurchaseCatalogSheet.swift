import SwiftUI

/// Find what came in a purchase. Each tap adds one copy to the purchase's
/// list, so three taps on a booster pack is three packs. Sealed products rank
/// first, because a purchase is usually sealed.
struct PurchaseCatalogSheet: View {
    @Binding var lines: [PurchaseIntake.Line]

    @Environment(\.dismiss) private var dismiss
    @Environment(CatalogController.self) private var catalog
    @State private var search = SearchModel(context: .buying)

    var body: some View {
        @Bindable var search = search
        NavigationStack {
            List {
                Section {
                    Picker("Kind", selection: $search.filter.kind) {
                        ForEach(SearchFilter.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    if catalog.database == nil {
                        Text("The catalog is not installed yet.")
                            .foregroundStyle(.secondary)
                    } else if search.hits.isEmpty, !search.isEmptyQuery, !search.isSearching {
                        Text("No product matches. Write it in on the purchase instead.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(search.hits.prefix(40)) { hit in
                        Button {
                            Task { await add(hit) }
                        } label: {
                            HStack {
                                ProductRow(hit: hit)
                                if let count = count(hit) {
                                    Text("\(count)")
                                        .font(.callout.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(.tint, in: Capsule())
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    if !lines.isEmpty {
                        Text("\(copies) on the purchase. Tap a product again for one more copy.")
                    }
                }
            }
            .searchable(text: $search.text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name or number")
            .navigationTitle("What was in it")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                search.database = { [weak catalog] in catalog?.database }
            }
        }
    }

    private var copies: Int { lines.reduce(0) { $0 + $1.quantity } }

    private func count(_ hit: SearchHit) -> Int? {
        lines.first { $0.productId == hit.productId }?.quantity
    }

    private func add(_ hit: SearchHit) async {
        var printings: [String] = []
        if count(hit) == nil, let db = catalog.database {
            let prices = try? await CatalogSearch(database: db).prices(for: [hit.productId])
            printings = prices?[hit.productId]?.map(\.subTypeName) ?? []
        }
        lines = PurchaseIntake.adding(hit, printings: printings, to: lines)
    }
}
