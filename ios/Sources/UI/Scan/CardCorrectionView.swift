import SwiftUI

/// Fixes one card. Candidates first, then the same search everyone else uses,
/// in the scanning context. Confirming returns straight to the scanner.
struct CardCorrectionView: View {
    let card: OwnedCard
    let model: ScanSessionModel

    @Environment(\.dismiss) private var dismiss
    @Environment(CatalogController.self) private var catalog
    @State private var search = SearchModel(context: .scanning)
    @State private var showDelete = false

    var body: some View {
        @Bindable var search = search
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        ProductThumbnail(urlString: model.hit(for: card)?.imageUrl, isSealed: false)
                            .frame(width: 56, height: 78)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.hit(for: card)?.name ?? "Not identified")
                                .font(.headline)
                            if let hit = model.hit(for: card) {
                                Text(hit.setName).font(.footnote).foregroundStyle(.secondary)
                                if let number = hit.number { Text(number).font(.footnote.monospacedDigit()) }
                            }
                            HStack(spacing: 6) {
                                ConfidenceMarker(confidence: card.matchConfidence, identified: card.isIdentified)
                                Text(confidenceLabel).font(.caption).foregroundStyle(.secondary)
                            }
                            if card.ocrName != nil || card.ocrNumber != nil {
                                Text("Read: \([card.ocrName, card.ocrNumber].compactMap { $0 }.joined(separator: " · "))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            if let cert = card.certNumber {
                                Text("Cert \(cert) (\(card.graderRaw ?? "grader unknown"))")
                                    .font(.caption)
                            }
                        }
                    }
                    if card.matchConfidence == .uncertain, card.isIdentified {
                        Button("This is right") {
                            model.confirm(card)
                            dismiss()
                        }
                    }
                }

                if card.candidateProductIds.count > 1 {
                    Section("Candidates") {
                        ForEach(card.candidateProductIds, id: \.self) { id in
                            if let hit = model.hits[id] {
                                candidateRow(hit)
                            }
                        }
                    }
                }

                let printings = model.availablePrintings(for: card)
                if printings.count > 1 {
                    Section("Printing") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(printings, id: \.self) { printing in
                                    Chip(title: printing, isSelected: card.printing == printing) {
                                        model.setPrinting(printing, for: [card])
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Condition") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(CardCondition.allCases, id: \.self) { condition in
                                Chip(title: condition.rawValue, isSelected: card.condition == condition.rawValue) {
                                    model.setCondition(condition.rawValue, for: [card])
                                }
                            }
                        }
                    }
                    Toggle("Bulk (identity only, no basis)", isOn: Binding(
                        get: { card.isBulk },
                        set: { model.setBulk($0, for: [card]) }
                    ))
                }

                Section("Search") {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Name or number", text: $search.text)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    ForEach(search.hits.prefix(25)) { hit in
                        candidateRow(hit)
                    }
                }

                Section {
                    Button("Delete this card", role: .destructive) { showDelete = true }
                }
            }
            .navigationTitle("Correct")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Delete this card?", isPresented: $showDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    model.delete([card])
                    dismiss()
                }
            }
            .task {
                search.database = { [weak catalog] in catalog?.database }
                // The number is exact and lists every product that carries it, which
                // is the useful starting point. The name is the fallback.
                if search.text.isEmpty, let seed = card.ocrNumber ?? card.ocrName {
                    search.text = seed
                }
            }
        }
    }

    private var confidenceLabel: String {
        switch card.matchConfidence {
        case .manual: return "Chosen by hand"
        case .certain: return "Certain"
        case .likely: return "Likely"
        case .uncertain: return card.isIdentified ? "Uncertain, check it" : "Not matched"
        }
    }

    private func candidateRow(_ hit: SearchHit) -> some View {
        Button {
            model.assign(card, to: hit)
            dismiss()
        } label: {
            HStack {
                ProductRow(hit: hit)
                if hit.productId == card.productId {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
