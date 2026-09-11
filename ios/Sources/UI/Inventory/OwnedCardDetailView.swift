import SwiftData
import SwiftUI

/// One owned card: catalog data, the basis breakdown, the source purchase, and
/// the edits that need no other model.
struct OwnedCardDetailView: View {
    @Query private var cards: [OwnedCard]

    @Environment(InventoryModel.self) private var model
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showDelete = false

    /// The card comes from the store by id, so the view does not depend on
    /// the inventory list staying alive behind it.
    init(cardID: UUID) {
        _cards = Query(filter: #Predicate<OwnedCard> { $0.id == cardID })
    }

    var body: some View {
        if let card = cards.first {
            OwnedCardDetailBody(card: card, model: model, showDelete: $showDelete) {
                modelContext.delete(card)
                try? modelContext.save()
                dismiss()
            }
        } else {
            ContentUnavailableView("Card not found", systemImage: "questionmark.square", description: Text("It may have been deleted."))
        }
    }
}

private struct OwnedCardDetailBody: View {
    let card: OwnedCard
    let model: InventoryModel
    @Binding var showDelete: Bool
    var onDelete: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \OwnedCard.acquiredAt, order: .reverse) private var allCards: [OwnedCard]
    @State private var tagTarget: TagSheetTarget?
    @State private var markingGraded = false

    private var hit: SearchHit? { model.hits[card.productId] }
    private var printings: [String] { model.prices[card.productId]?.map(\.subTypeName) ?? [] }

    var body: some View {
        List {
            identity
            tags
            basis
            GradedCompsSection(card: card)
            source
            edits
            Section {
                Button("Delete card", role: .destructive) { showDelete = true }
            }
        }
        .navigationTitle(hit?.name ?? "Card")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this card from inventory?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: onDelete)
        }
        .sheet(item: $tagTarget) { target in
            TagSheet(target: target, uses: model.tagUses(in: allCards), allCards: allCards.filter(\.isCommitted)) {
                model.invalidateHaystacks()
            }
        }
        .sheet(isPresented: $markingGraded) {
            MarkGradedSheet(cards: [card], name: { hit?.name ?? $0.ocrName ?? "Card" }) {
                model.invalidateHaystacks()
            }
        }
        .task(id: card.productId) {
            await model.load(for: [card])
        }
    }

    private var identity: some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                if card.isSlabbed {
                    SlabBadge(imageUrl: hit?.imageUrl, grader: card.graderRaw, grade: card.gradeLabel, cert: card.certNumber)
                        .frame(width: 110, height: 168)
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
                    if card.isSlabbed {
                        let grade = card.gradeLabel.map { " \($0)" } ?? ""
                        let cert = card.certNumber.map { " · cert \($0)" } ?? ""
                        Text("\((card.graderRaw ?? "slab").uppercased())\(grade)\(cert)").font(.footnote)
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
            // What it might come back worth, per grader, from the comps he
            // entered. The grader it is out at is the one that matters now.
            let atGrader = GradedComps.graderAtGrader(tags: card.tags)
            ForEach(GradedComps.graders, id: \.self) { grader in
                if let range = GradedComps.range(for: grader, in: card.effectiveCompCents) {
                    LabeledContent("If \(grader.uppercased()) grades it") {
                        Text(GradedComps.rangeText(range))
                            .monospacedDigit()
                            .fontWeight(atGrader == grader ? .semibold : .regular)
                    }
                }
            }
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
                if card.basisIsAllocated {
                    Text("This cost was split out of the purchase. The pack result is still the truer read, but this is the figure to compare a sale against.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if card.totalBasisCents == 0 {
                Text("No cost on this card yet. Set one from the review screen, or attach it to a purchase.")
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

    /// Free-form labels. They replaced the status picker, so the reserved
    /// labels ("sold", "at grader", "graded", "listed", "lost") live here too.
    private var tags: some View {
        Section("Tags") {
            if card.tags.isEmpty {
                Text("No labels.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(card.tags, id: \.self) { tag in
                            Chip(title: tag, systemImage: "xmark", isSelected: true) {
                                CardTagEditor(context: modelContext).remove(tag, from: [card])
                                model.invalidateHaystacks()
                            }
                        }
                    }
                }
            }
            Button {
                tagTarget = TagSheetTarget(cards: [card])
            } label: {
                Label("Add tag…", systemImage: "tag")
            }
        }
    }

    private var edits: some View {
        Section("Edit") {
            if printings.count > 1 {
                chipRow("Printing", printings, selected: card.printing) { card.printing = $0; save() }
            }
            chipRow("Condition", CardCondition.allCases.map(\.rawValue), selected: card.condition) { card.condition = $0; save() }
            Button {
                markingGraded = true
            } label: {
                Label(card.gradeLabel == nil ? "Mark as graded…" : "Edit the grade…", systemImage: "seal")
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

    private func save() {
        try? modelContext.save()
    }
}
