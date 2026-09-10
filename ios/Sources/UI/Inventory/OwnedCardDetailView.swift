import SwiftData
import SwiftUI

/// One owned card: catalog data, the basis breakdown, the source purchase, and
/// the edits that need no other model.
struct OwnedCardDetailView: View {
    let card: OwnedCard
    let model: InventoryModel

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showDelete = false

    private var hit: SearchHit? { model.hits[card.productId] }
    private var printings: [String] { model.prices[card.productId]?.map(\.subTypeName) ?? [] }

    var body: some View {
        List {
            identity
            basis
            source
            edits
            Section {
                Button("Delete card", role: .destructive) { showDelete = true }
            }
        }
        .navigationTitle(hit?.name ?? "Card")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this card from inventory?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                modelContext.delete(card)
                try? modelContext.save()
                dismiss()
            }
        }
    }

    private var identity: some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                if let cert = card.certNumber {
                    SlabBadge(imageUrl: hit?.imageUrl, grader: card.graderRaw, cert: cert)
                        .frame(width: 110, height: 160)
                } else {
                    ProductThumbnail(urlString: hit?.imageUrl?.replacingOccurrences(of: "_200w", with: "_400w"), isSealed: false)
                        .frame(width: 110, height: 154)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(hit?.name ?? card.ocrName ?? "Unknown").font(.title3.weight(.semibold))
                    if let hit {
                        Text(hit.setName).foregroundStyle(.secondary)
                        if let number = hit.number { Text(number).monospacedDigit() }
                        if let rarity = hit.rarity, rarity != "None" { Text(rarity).font(.footnote).foregroundStyle(.secondary) }
                    }
                    HStack(spacing: 6) {
                        ConfidenceMarker(confidence: card.matchConfidence, identified: card.isIdentified, isBulk: card.isBulk)
                        Text(card.matchConfidence.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                    }
                    if let cert = card.certNumber {
                        Text("\((card.graderRaw ?? "slab").uppercased()) cert \(cert)").font(.footnote)
                    }
                }
            }
            .listRowSeparator(.hidden)
            if let hit {
                NavigationLink(value: hit) {
                    Label("Catalog entry and prices", systemImage: "books.vertical")
                }
            }
        }
    }

    private var basis: some View {
        Section("Value") {
            LabeledContent("Market", value: model.marketCents(for: card)?.asCurrency ?? "—")
            LabeledContent("Acquisition basis") {
                HStack(spacing: 4) {
                    Text(card.acquisitionBasisCents.asCurrency).monospacedDigit()
                    if card.basisIsAllocated {
                        Text("allocated").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if card.gradingBasisCents > 0 {
                LabeledContent("Grading basis", value: card.gradingBasisCents.asCurrency)
            }
            LabeledContent("Total basis", value: card.totalBasisCents.asCurrency)
            if let diff = InventoryRow(card: card, hit: hit, marketCents: model.marketCents(for: card)).unrealizedCents {
                LabeledContent("Unrealized") {
                    Text((diff >= 0 ? "+" : "−") + abs(diff).asCurrency)
                        .monospacedDigit()
                        .foregroundStyle(diff >= 0 ? .green : .red)
                }
            } else if card.basisIsAllocated {
                Text("This basis was split across the purchase, so it is not a real cost for this card. Read the result at the purchase level.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var source: some View {
        if let purchase = card.sourceItem?.purchase {
            Section("Source") {
                LabeledContent("Vendor", value: purchase.vendor.isEmpty ? "—" : purchase.vendor)
                LabeledContent("Date", value: purchase.date.formatted(date: .abbreviated, time: .omitted))
                LabeledContent("Landed cost", value: purchase.landedCostCents.asCurrency)
                LabeledContent("Lines", value: "\(purchase.items.count)")
                if !purchase.note.isEmpty {
                    Text(purchase.note).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        if let session = card.scanSession {
            Section("Scan") {
                LabeledContent("Scanned", value: card.scannedAt.formatted(date: .abbreviated, time: .shortened))
                if let committed = session.committedAt {
                    LabeledContent("Committed", value: committed.formatted(date: .abbreviated, time: .shortened))
                }
                if card.ocrName != nil || card.ocrNumber != nil {
                    LabeledContent("Read", value: [card.ocrName, card.ocrNumber].compactMap { $0 }.joined(separator: " · "))
                }
            }
        }
    }

    private var edits: some View {
        Section("Edit") {
            if printings.count > 1 {
                chipRow("Printing", printings, selected: card.printing) { card.printing = $0; save() }
            }
            chipRow("Condition", CardCondition.allCases.map(\.rawValue), selected: card.condition) { card.condition = $0; save() }
            chipRow("Status", [CardStatus.owned, .listed, .atGrader, .gradedReturned, .lost].map(\.rawValue), selected: card.statusRaw, titles: statusTitle) {
                card.statusRaw = $0; save()
            }
            Toggle("Personal collection (not inventory)", isOn: Binding(get: { card.isPersonalCollection }, set: { card.isPersonalCollection = $0; save() }))
            Toggle("Bulk (identity only, no basis)", isOn: Binding(get: { card.isBulk }, set: { card.isBulk = $0; save() }))
            if card.matchConfidence == .uncertain {
                Button("Confirm this identification") { card.matchConfidence = .manual; save() }
            }
        }
    }

    private func chipRow(_ label: String, _ options: [String], selected: String, titles: @escaping (String) -> String = { $0 }, onPick: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(options, id: \.self) { option in
                        Chip(title: titles(option), isSelected: option == selected) { onPick(option) }
                    }
                }
            }
        }
    }

    private func statusTitle(_ raw: String) -> String {
        switch CardStatus(rawValue: raw) {
        case .owned: return "Owned"
        case .atGrader: return "At grader"
        case .gradedReturned: return "Graded"
        case .listed: return "Listed"
        case .sold: return "Sold"
        case .lost: return "Lost"
        case nil: return raw
        }
    }

    private func save() {
        try? modelContext.save()
    }
}
