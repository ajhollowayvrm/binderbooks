import SwiftUI

/// Pick the catalog product a card is. It uses the same search as the scan
/// correction screen, with singles ranked first.
struct CatalogPickSheet: View {
    /// The product the card is now. Zero for a card with none.
    var currentProductId: Int
    /// The text the search starts with.
    var seed: String
    var onPicked: (SearchHit) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(CatalogController.self) private var catalog
    @State private var search = SearchModel(context: .intake)

    var body: some View {
        @Bindable var search = search
        NavigationStack {
            List {
                if catalog.database == nil {
                    Text("The catalog is not installed yet.")
                        .foregroundStyle(.secondary)
                } else if search.hits.isEmpty, !search.isEmptyQuery, !search.isSearching {
                    Text("No product matches.")
                        .foregroundStyle(.secondary)
                }
                ForEach(search.hits.prefix(40)) { hit in
                    Button {
                        onPicked(hit)
                        dismiss()
                    } label: {
                        HStack {
                            ProductRow(hit: hit)
                            if hit.productId == currentProductId {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $search.text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name or number")
            .navigationTitle("Change card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task {
                search.database = { [weak catalog] in catalog?.database }
                if search.text.isEmpty { search.text = seed }
            }
        }
    }
}
