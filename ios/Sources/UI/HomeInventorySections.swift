import SwiftData
import SwiftUI

/// The parts of the home that come from the collection store.
struct HomeInventorySections: View {
    var onResumeSession: () -> Void

    @Environment(CatalogController.self) private var catalog
    @Query(filter: #Predicate<ScanSession> { $0.committedAt == nil }, sort: \ScanSession.startedAt, order: .reverse)
    private var openSessions: [ScanSession]
    @Query(sort: \OwnedCard.scannedAt, order: .reverse)
    private var cards: [OwnedCard]

    @State private var hits: [Int: SearchHit] = [:]

    /// Committed cards the scanner was unsure about, newest first.
    private var flagged: [OwnedCard] {
        cards.filter { $0.isCommitted && $0.matchConfidence == .uncertain }.prefix(20).map { $0 }
    }

    private var inventoryCount: Int { cards.filter(\.isCommitted).count }

    var body: some View {
        if inventoryCount > 0 {
            Section {
                NavigationLink {
                    InventoryView()
                } label: {
                    HStack {
                        Image(systemName: "tray.full")
                        Text("Inventory")
                        Spacer()
                        Text("\(inventoryCount) cards")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        if let open = openSessions.first {
            Section {
                Button(action: onResumeSession) {
                    HStack {
                        Image(systemName: "camera.badge.clock")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Scan session in progress")
                                .foregroundStyle(.primary)
                            Text("\(open.cards.count) cards, started \(open.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("Resume")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
        }

        if !flagged.isEmpty {
            Section("Flagged from recent scans") {
                ForEach(flagged) { card in
                    HStack(spacing: 12) {
                        ProductThumbnail(urlString: hits[card.productId]?.imageUrl, isSealed: false)
                            .frame(width: 36, height: 50)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hits[card.productId]?.name ?? card.ocrName ?? "Unknown")
                                .lineLimit(1)
                            Text([hits[card.productId]?.setName, card.printing.isEmpty ? nil : card.printing].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        ConfidenceMarker(confidence: card.matchConfidence, identified: card.isIdentified)
                    }
                }
            }
            .task(id: flagged.map(\.productId)) {
                guard let db = catalog.database else { return }
                let ids = flagged.map(\.productId).filter { $0 > 0 && hits[$0] == nil }
                if let rows = try? await CatalogSearch(database: db).hits(ids: ids) {
                    for row in rows { hits[row.productId] = row }
                }
            }
        }
    }
}
