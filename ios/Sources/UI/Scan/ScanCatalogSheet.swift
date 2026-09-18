import SwiftUI

/// Add cards to the scan session by name, in place of the camera. For a card
/// the camera will not read, or a stack he would rather type.
///
/// Each tap adds one copy, the way a scan logs one card, so a second tap on the
/// same row is a second copy. The cards join the session: a purchase's scan
/// puts them on the purchase, and a rip's scan makes them pulls of the rip.
/// Singles only. A sealed product goes in through the plus menu or a purchase.
struct ScanCatalogSheet: View {
    let model: ScanSessionModel

    @Environment(\.dismiss) private var dismiss
    @Environment(CatalogController.self) private var catalog
    @State private var search: SearchModel = {
        let model = SearchModel(context: .intake)
        model.filter.kind = .singles
        return model
    }()
    /// The copies each product got in this sheet, for the badge on its row.
    @State private var added: [Int: Int] = [:]

    var body: some View {
        @Bindable var search = search
        NavigationStack {
            List {
                Section {
                    if catalog.database == nil {
                        Text("The catalog is not installed yet.")
                            .foregroundStyle(.secondary)
                    } else if search.hits.isEmpty, !search.isEmptyQuery, !search.isSearching {
                        Text("No card matches.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(search.hits.prefix(40)) { hit in
                        Button {
                            added[hit.productId, default: 0] += 1
                            Task { await model.add(hit) }
                        } label: {
                            HStack {
                                ProductRow(hit: hit)
                                if let count = added[hit.productId] {
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
                    let total = added.values.reduce(0, +)
                    if total > 0 {
                        Text(total == 1 ? "1 card added to this scan. Tap a card again for another copy." : "\(total) cards added to this scan. Tap a card again for another copy.")
                    }
                }
            }
            .searchable(text: $search.text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name or number")
            .navigationTitle("Add from the catalog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                search.database = { [weak catalog] in catalog?.database }
            }
        }
    }
}
