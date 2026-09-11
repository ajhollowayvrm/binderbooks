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

                // The pattern printings. These share a name and a number and
                // differ only in the foil stamped across them, so a row of text
                // cannot ask the question — the art has to be big enough to see
                // the pattern on. This is the one choice the scanner cannot make
                // for him when the catalog has no reference image for a
                // printing, which for most of them it does not.
                if patternFamily.count > 1 {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(patternFamily) { hit in
                                    patternTile(hit)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text("Which printing")
                    } footer: {
                        Text("Same card, same number. Only the foil differs.")
                    }
                }

                let others = card.candidateProductIds.filter { id in
                    !patternFamily.contains { $0.productId == id }
                }
                if others.count > 1 || (others.count == 1 && patternFamily.isEmpty) {
                    Section("Candidates") {
                        ForEach(others, id: \.self) { id in
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

    /// The printings of this one card: same set, same number, names that differ
    /// only by a qualifier. Empty unless there are at least two, because one
    /// printing is not a choice.
    private var patternFamily: [SearchHit] {
        let hits = card.candidateProductIds.compactMap { model.hits[$0] }
        guard let anchor = model.hit(for: card) ?? hits.first else { return [] }
        let family = hits.filter { CardMatcher.isVariantSibling($0, of: anchor) }
        return family.count > 1 ? family : []
    }

    /// One printing, big enough to see the foil on. The qualifier is the label,
    /// because "Snivy" three times over tells him nothing.
    private func patternTile(_ hit: SearchHit) -> some View {
        Button {
            model.assign(card, to: hit)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    ProductThumbnail(urlString: hit.imageUrl, isSealed: false)
                        .frame(width: 104, height: 145)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(
                                    hit.productId == card.productId ? Color.accentColor : Color.clear,
                                    lineWidth: 3
                                )
                        }
                    if hit.productId == card.productId {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(4)
                    }
                }
                Text(CardMatcher.qualifier(of: hit) ?? "Plain")
                    .font(.caption)
                    .lineLimit(2)
                    .frame(width: 104, alignment: .leading)
                if let price = hit.priceLabel {
                    Text(price)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
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
