import SwiftData
import SwiftUI

/// Owned cards with market value, basis, and the difference where the basis is
/// real. Filters are chips. Graded cards render as slabs.
struct InventoryView: View {
    @Environment(CatalogController.self) private var catalog
    @Query(sort: \OwnedCard.acquiredAt, order: .reverse) private var cards: [OwnedCard]
    @State private var model = InventoryModel()
    @State private var allSets: [SetSummary] = []
    @State private var showSetPicker = false

    private var rows: [InventoryRow] { model.rows(from: cards) }

    var body: some View {
        let rows = rows
        let summary = model.summary(of: rows)
        VStack(spacing: 0) {
            summaryHeader(summary)
            filterRow
            Divider()
            if rows.isEmpty {
                ContentUnavailableView {
                    Label(model.filter.isActive ? "No cards match" : "No inventory yet", systemImage: "tray")
                } description: {
                    Text(model.filter.isActive ? "Clear a filter." : "Commit a scan session and the cards land here.")
                }
            } else {
                List(rows) { row in
                    NavigationLink(value: row.card.id) {
                        OwnedCardRow(row: row)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Inventory")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: UUID.self) { id in
            if let card = cards.first(where: { $0.id == id }) {
                OwnedCardDetailView(card: card, model: model)
            }
        }
        .sheet(isPresented: $showSetPicker) {
            SetPickerSheet(sets: model.sets(in: cards, from: allSets), selected: model.filter.groupId) { groupId in
                model.filter.groupId = groupId
            }
        }
        .task(id: catalog.database?.path) {
            model.database = { [weak catalog] in catalog?.database }
            model.invalidate()
            await model.load(for: cards)
            if let db = catalog.database, allSets.isEmpty {
                allSets = (try? await CatalogSearch(database: db).sets()) ?? []
            }
        }
        .task(id: cards.count) {
            await model.load(for: cards)
        }
    }

    private func summaryHeader(_ s: InventorySummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            stat("Cards", "\(s.cardCount)")
            stat("Market", s.marketCents.asCurrency)
            stat("Basis", s.basisCents.asCurrency)
            if s.pricedBasisCents > 0 || s.pricedMarketCents > 0 {
                stat(
                    "Unrealized",
                    (s.unrealizedCents >= 0 ? "+" : "−") + abs(s.unrealizedCents).asCurrency,
                    color: s.unrealizedCents >= 0 ? .green : .red
                )
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .overlay(alignment: .bottomLeading) {
            if s.allocatedCount > 0 {
                Text("Unrealized covers priced cards only. \(s.allocatedCount) carry an allocated basis.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal)
                    .offset(y: 6)
            }
        }
        .padding(.bottom, s.allocatedCount > 0 ? 10 : 0)
    }

    private func stat(_ label: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(color)
        }
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let set = allSets.first(where: { $0.groupId == model.filter.groupId }) {
                    Chip(title: set.name, systemImage: "xmark", isSelected: true) { model.filter.groupId = nil }
                } else {
                    Chip(title: "Set", systemImage: "square.stack", isSelected: false) { showSetPicker = true }
                }
                Divider().frame(height: 20)
                ForEach([CardStatus.owned, .listed, .atGrader, .gradedReturned, .lost], id: \.self) { status in
                    Chip(title: statusTitle(status), isSelected: model.filter.statuses.contains(status)) {
                        toggle(&model.filter.statuses, status)
                    }
                }
                Divider().frame(height: 20)
                Chip(title: "Uncertain", systemImage: "questionmark", isSelected: model.filter.confidences.contains(.uncertain)) {
                    toggle(&model.filter.confidences, .uncertain)
                }
                Chip(title: "Slabs", isSelected: model.filter.slabsOnly) { model.filter.slabsOnly.toggle() }
                Chip(title: "Hide bulk", isSelected: model.filter.hideBulk) { model.filter.hideBulk.toggle() }
                Chip(title: "Personal", isSelected: model.filter.personalOnly) { model.filter.personalOnly.toggle() }
                if model.filter.isActive {
                    Button("Clear") { model.filter = InventoryFilter() }
                        .font(.subheadline)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private func toggle<T: Hashable>(_ set: inout Set<T>, _ value: T) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }

    private func statusTitle(_ status: CardStatus) -> String {
        switch status {
        case .owned: return "Owned"
        case .atGrader: return "At grader"
        case .gradedReturned: return "Graded"
        case .listed: return "Listed"
        case .sold: return "Sold"
        case .lost: return "Lost"
        }
    }
}
