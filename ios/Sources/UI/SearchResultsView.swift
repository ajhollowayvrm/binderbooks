import SwiftData
import SwiftUI

/// One query, two sections: the cards he owns first, then the catalog.
///
/// The two halves answer at different speeds on purpose. The collection pass is
/// a string scan over his own cards in memory, so it answers on every keystroke
/// with no debounce. The catalog keeps `SearchModel`'s 150 ms debounce and its
/// sub-50 ms query. The catalog header stays visible from the first keystroke,
/// so the list does not jump when the second half lands.
struct SearchResultsView: View {
    @Bindable var model: SearchModel

    @Environment(CatalogController.self) private var catalog
    @Environment(InventoryModel.self) private var inventory
    @Query(sort: \OwnedCard.acquiredAt, order: .reverse) private var cards: [OwnedCard]
    @State private var showSetPicker = false
    @AppStorage(cardLayoutKey) private var layout: CardLayout = .grid

    /// The inventory chips do not apply here. This section answers the query,
    /// not the state of another page.
    private var ownedRows: [InventoryRow] {
        inventory.rows(from: cards, query: model.text, applyFilter: false)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                FilterChipRow(model: model, showSetPicker: $showSetPicker)
                CardLayoutButton(layout: $layout)
            }
            Divider()
            results
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
    }

    @ViewBuilder
    private var results: some View {
        let owned = ownedRows
        switch layout {
        case .list:
            List {
                if !owned.isEmpty {
                    Section {
                        ForEach(owned) { row in
                            NavigationLink(value: AppRoute.ownedCard(row.card.id)) {
                                OwnedCardRow(row: row)
                            }
                        }
                    } header: {
                        // Rows, not the sum of quantity. A row shows its own ×N,
                        // and the inventory tiles are the place that sums.
                        Text("In your collection (\(owned.count))").textCase(nil)
                    }
                }
                Section {
                    catalogRows
                } header: {
                    Text("Catalog (\(catalogCount))").textCase(nil)
                } footer: {
                    catalogFooter
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
        case .grid:
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !owned.isEmpty {
                        CardSectionHeader(title: "In your collection (\(owned.count))")
                        OwnedCardGrid(rows: owned)
                            .padding(.horizontal, 12)
                    }
                    CardSectionHeader(title: "Catalog (\(catalogCount))")
                    catalogGrid
                        .padding(.horizontal, 12)
                    catalogFooter
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    /// `200+` at the candidate limit, because an honest count matters more than
    /// a round number.
    private var catalogCount: String {
        model.hits.count >= CatalogSearch.candidateLimit ? "\(CatalogSearch.candidateLimit)+" : "\(model.hits.count)"
    }

    @ViewBuilder
    private var catalogRows: some View {
        if model.hits.isEmpty {
            catalogEmptyState
                .listRowSeparator(.hidden)
        } else {
            ForEach(model.hits) { hit in
                NavigationLink(value: hit) {
                    ProductRow(hit: hit)
                }
            }
        }
    }

    @ViewBuilder
    private var catalogGrid: some View {
        if model.hits.isEmpty {
            catalogEmptyState
        } else {
            ProductCardGrid(hits: model.hits)
        }
    }

    /// The spinner keeps the catalog header in place while the second half of
    /// the answer lands, so the list does not jump under his thumb.
    @ViewBuilder
    private var catalogEmptyState: some View {
        if model.isSearching {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.vertical, 12)
        } else if let message = model.errorMessage {
            Text(message)
                .foregroundStyle(.secondary)
        } else {
            Text("No catalog product matches \"\(model.text)\".")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var catalogFooter: some View {
        #if DEBUG
        if let duration = model.lastDuration {
            Text("in \(duration.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))")
        }
        #endif
    }
}
