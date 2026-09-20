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
    @Environment(InventorySelection.self) private var selection
    @Query(sort: \OwnedCard.acquiredAt, order: .reverse) private var cards: [OwnedCard]
    @State private var showSetPicker = false
    @State private var addingByHand = false
    @State private var showMasterSet = false
    @AppStorage(cardLayoutKey) private var layout: CardLayout = .grid

    /// The inventory chips do not apply here. This section answers the query,
    /// not the state of another page. The chips on **this** page do apply: with
    /// Sealed chosen, a hundred singles under "In your collection" was the
    /// wrong answer.
    private var ownedRows: [InventoryRow] {
        inventory.rows(from: cards, query: model.text, applyFilter: false).filter(matchesChips)
    }

    private func matchesChips(_ row: InventoryRow) -> Bool {
        let filter = model.filter
        if filter.kind != .all, (filter.kind == .sealed) != InventoryModel.isSealed(row.card, hit: row.hit) { return false }
        if let groupId = filter.groupId, row.hit?.groupId != groupId { return false }
        if !filter.categoryIds.isEmpty, !(row.hit.map { filter.categoryIds.contains($0.categoryId) } ?? false) { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                FilterChipRow(model: model, showSetPicker: $showSetPicker, showMasterSet: $showMasterSet)
                CardLayoutButton(layout: $layout)
            }
            Divider()
            // The query narrows the checklist, the same as it narrows results.
            if showMasterSet, let groupId = model.filter.groupId {
                MasterSetView(groupId: groupId, query: model.text)
            } else {
                results
            }
        }
        // The owned cards select the same way as on the inventory page, and
        // the selection lives through the keystroke that brought him here.
        .inventorySelectionChrome(rows: ownedRows)
        .sheet(isPresented: $showSetPicker) {
            SetPickerSheet(sets: model.sets, selected: model.filter.groupId) { groupId in
                model.filter.groupId = groupId
            }
        }
        .sheet(isPresented: $addingByHand) {
            AddToInventorySheet(handEnteredName: model.text)
        }
        .task(id: catalog.database?.path) {
            model.database = { [weak catalog] in catalog?.database }
            await model.loadFacets()
            model.schedule()
        }
    }

    @ViewBuilder
    private var results: some View {
        // Copies of one thing are one line here too, the same as the
        // inventory page.
        let owned = InventoryStack.stacks(ownedRows)
        switch layout {
        case .list:
            List {
                if !owned.isEmpty {
                    Section {
                        ForEach(owned) { stack in
                            SelectableStackRow(stack: stack)
                        }
                    } header: {
                        // Lines, not the sum of quantity. A line shows its own
                        // ×N, and the inventory tiles are the place that sums.
                        Text("In your collection (\(owned.count))").textCase(nil)
                    }
                }
                // Catalog products are not his, so they cannot be selected.
                // They step aside while he selects.
                if !selection.isSelecting {
                    Section {
                        catalogRows
                        if !model.isSearching {
                            addByHandButton
                        }
                    } header: {
                        Text("Catalog (\(catalogCount))").textCase(nil)
                    } footer: {
                        catalogFooter
                    }
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
        case .grid:
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !owned.isEmpty {
                        CardSectionHeader(title: "In your collection (\(owned.count))")
                        SelectableCardGrid(stacks: owned)
                            .padding(.horizontal, 12)
                    }
                    if !selection.isSelecting {
                        CardSectionHeader(title: "Catalog (\(catalogCount))")
                        catalogGrid
                            .padding(.horizontal, 12)
                        if !model.isSearching {
                            addByHandButton
                                .padding(.horizontal, 12)
                                .padding(.top, 12)
                        }
                        catalogFooter
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    /// The road for a card the catalog does not carry, such as an Italian or a
    /// Korean print. The query fills the name, because he just typed it.
    private var addByHandButton: some View {
        Button {
            addingByHand = true
        } label: {
            Label("Not in the catalog? Add it by hand", systemImage: "square.and.pencil")
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
