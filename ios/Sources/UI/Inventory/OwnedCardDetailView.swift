import PhotosUI
import SwiftData
import SwiftUI
import UIKit

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
                CardPhotoStore.remove([card.id])
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
    @State private var confirmNoHits = false
    @State private var editingCost = false
    @State private var pickingProduct = false
    @State private var choosingPurchase = false
    @State private var ripTarget: TagSheetTarget?
    @State private var confirmMarkSChinese = false
    /// Copies the plus added while this screen is open.
    @State private var addedCopies = 0
    @State private var addError: String?
    /// Bumped after a photo is saved or removed, so the thumbnail — which
    /// reads a file at a URL that does not itself change — redraws.
    @State private var photoRefresh = UUID()

    private var hit: SearchHit? { model.hits[card.productId] }
    private var printings: [String] { model.prices[card.productId]?.map(\.subTypeName) ?? [] }

    var body: some View {
        List {
            if addedCopies > 0 || addError != nil {
                addedNote
            }
            identity
            sealed
            tags
            basis
            GradedCompsSection(card: card, categoryId: hit?.categoryId)
            source
            // A card with no catalog product: one he entered by hand, or an
            // imported row that never had one. He can name it here.
            if card.productId == 0, !card.isSealedSelf {
                ManualIdentitySection(card: card, onChange: { model.invalidateHaystacks() }, onPhotoChanged: { photoRefresh = UUID() })
            }
            edits
            Section {
                Button("Delete card", role: .destructive) { showDelete = true }
            }
        }
        .navigationTitle(card.displayName(hit) ?? "Card")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if CardEditor.canAddCopy(of: card) {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        addCopy()
                    } label: {
                        Label("Add another", systemImage: "plus")
                    }
                }
            }
        }
        .ripSheet($ripTarget) { model.invalidateHaystacks() }
        .confirmationDialog("No hits from this box?", isPresented: $confirmNoHits, titleVisibility: .visible) {
            Button("No hits", role: .destructive) { markNoHits() }
        } message: {
            Text("This removes the box from inventory with nothing pulled from it. Its cost stays on the books as a loss.")
        }
        .confirmationDialog("Delete this card from inventory?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: onDelete)
        }
        .confirmationDialog("Mark this card S-Chinese?", isPresented: $confirmMarkSChinese, titleVisibility: .visible) {
            Button("Mark as S-Chinese", role: .destructive) { markSChinese() }
        } message: {
            Text("This drops the catalog match. The card becomes untracked: your own name, price, and, if you add one, your own photo. No grading is tracked for it.")
        }
        .sheet(item: $tagTarget) { target in
            TagSheet(target: target, uses: model.tagUses(in: allCards), allCards: allCards.filter(\.isCommitted)) {
                model.invalidateHaystacks()
            }
        }
        .sheet(isPresented: $markingGraded) {
            MarkGradedSheet(cards: [card], name: { $0.displayName(hit) ?? "Card" }) {
                model.invalidateHaystacks()
            }
        }
        .sheet(isPresented: $editingCost) {
            EditCardCostSheet(card: card) { model.invalidateHaystacks() }
        }
        .sheet(isPresented: $pickingProduct) {
            CatalogPickSheet(currentProductId: card.productId, seed: card.displayName(hit) ?? card.ocrNumber ?? "") { picked in
                assign(picked)
            }
        }
        .sheet(isPresented: $choosingPurchase) {
            ChoosePurchaseSheet(cards: [card]) { model.invalidateHaystacks() }
        }
        .task(id: card.productId) {
            await model.load(for: [card])
        }
        #if DEBUG
        // `CT_CHOOSE_PURCHASE=1` opens the sheet, because simctl cannot tap.
        .onAppear {
            if ProcessInfo.processInfo.environment["CT_CHOOSE_PURCHASE"] == "1" { choosingPurchase = true }
        }
        #endif
    }

    private var identity: some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                if card.isSlabbed {
                    SlabBadge(imageUrl: hit?.imageUrl, grader: card.graderRaw, grade: card.gradeLabel, cert: card.certNumber)
                        .frame(width: 110, height: 168)
                } else {
                    ProductThumbnail(urlString: card.photoURLString ?? hit?.imageUrl?.replacingOccurrences(of: "_200w", with: "_400w"), isSealed: card.isSealedSelf)
                        .frame(width: 110, height: 154)
                        .id(photoRefresh)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(card.displayName(hit) ?? "Unknown").font(.title3.weight(.semibold))
                    if let hit {
                        Text(hit.setName).foregroundStyle(.secondary)
                        if let number = hit.number { Text(number).monospacedDigit() }
                        if let rarity = hit.rarity, rarity != "None" { Text(rarity).font(.footnote).foregroundStyle(.secondary) }
                    } else if card.isHandEntered {
                        if let setName = card.setName(nil) { Text(setName).foregroundStyle(.secondary) }
                        if let number = card.number(nil) { Text(number).monospacedDigit() }
                        Text("\(CardLanguage.name(card.language)) · entered by hand").font(.footnote).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        ConfidenceMarker(confidence: card.matchConfidence, identified: card.hasIdentity, isBulk: card.isBulk)
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

    /// Only on the self-card that stands for an unopened box. Ripping and
    /// dumping a dud are the same choice: what left inventory, one way or the
    /// other.
    @ViewBuilder
    private var sealed: some View {
        if card.isSealedSelf {
            Section {
                Button {
                    ripTarget = TagSheetTarget(cards: [card])
                } label: {
                    Label("Rip it", systemImage: "camera")
                }
                Button("No hits", role: .destructive) {
                    confirmNoHits = true
                }
            } header: {
                Text("Sealed")
            } footer: {
                Text("Scan what comes out. The cards take this box's cost. A dud with nothing in it still leaves inventory — mark it No hits instead of ripping.")
            }
        }
    }

    private var basis: some View {
        Section("Value") {
            LabeledContent(card.isHandEntered ? "Your value" : "Value", value: model.marketCents(for: card)?.asCurrency ?? "—")
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
            LabeledContent("Acquired", value: card.acquiredAt.formatted(date: .abbreviated, time: .omitted))
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
                Text("No cost on this card yet. Tap Edit cost to set one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                editingCost = true
            } label: {
                Label("Edit cost…", systemImage: "dollarsign.circle")
            }
        }
    }

    /// Always shown. A card with no purchase has no cost to split, and he can
    /// only fix a gap he can see.
    @ViewBuilder
    private var source: some View {
        let purchase = card.sourceItem?.purchase
        Section {
            if let purchase {
                NavigationLink(value: LedgerEntry.Kind.purchase(purchase.id)) {
                    LabeledContent("Vendor", value: purchase.vendor.isEmpty ? "—" : purchase.vendor)
                }
                LabeledContent("Date", value: purchase.date.formatted(date: .abbreviated, time: .omitted))
                LabeledContent("Landed cost", value: purchase.landedCostCents.asCurrency)
                LabeledContent("Lines", value: "\(purchase.items.count)")
                if !purchase.note.isEmpty {
                    Text(purchase.note).font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("Purchase", value: "None")
            }
            Button {
                choosingPurchase = true
            } label: {
                Label(purchase == nil ? "Choose a purchase…" : "Change purchase…", systemImage: "cart")
            }
        } header: {
            Text("Source")
        } footer: {
            if purchase == nil {
                Text("With no purchase, this card has only a cost you typed. Choose where it came from, and it takes its share of that purchase.")
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
            if !card.isSealedSelf {
                Button {
                    pickingProduct = true
                } label: {
                    Label(card.isIdentified ? "Change card…" : "Find in catalog…", systemImage: "arrow.triangle.2.circlepath")
                }
                if !card.isSChinese {
                    Button {
                        confirmMarkSChinese = true
                    } label: {
                        Label("Mark as S-Chinese…", systemImage: "character.book.closed")
                    }
                }
            }
            if printings.count > 1 {
                chipRow("Printing", printings, selected: card.printing) { card.printing = $0; save() }
            }
            chipRow("Condition", CardCondition.allCases.map(\.rawValue), selected: card.condition) { card.condition = $0; save() }
            Button {
                markingGraded = true
            } label: {
                Label(card.gradeLabel == nil ? "Mark as graded…" : "Edit the grade…", systemImage: "seal")
            }
            .disabled(card.isSChinese)
            if card.isSChinese {
                Text("Grading is not tracked for S-Chinese cards.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Personal collection (not inventory)", isOn: Binding(get: { card.isPersonalCollection }, set: { card.isPersonalCollection = $0; save() }))
            Toggle("Bulk (identity only, no basis)", isOn: Binding(get: { card.isBulk }, set: { card.isBulk = $0; save() }))
            if card.isBulk {
                Stepper("Quantity: \(card.quantity)", value: Binding(get: { max(1, card.quantity) }, set: { card.quantity = $0; save() }), in: 1...9_999)
            }
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

    /// How many copies of this card he holds now, the way the inventory line
    /// counts them.
    private var heldCopies: Int {
        InventoryStack.stack(of: card.id, in: model.rows(from: allCards, applyFilter: false))?.copies ?? max(1, card.quantity)
    }

    private var addedNote: some View {
        Section {
            if let addError {
                Text(addError).foregroundStyle(.red)
            } else {
                Label("Added \(addedCopies) \(addedCopies == 1 ? "copy" : "copies"). You hold \(heldCopies).", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        } footer: {
            Text("A new copy has no labels, no purchase, and no cost. Tap the stack on the inventory page to see each copy.")
        }
    }

    private func addCopy() {
        do {
            try CardEditor.addCopy(of: card, context: modelContext)
            addedCopies += 1
            addError = nil
            model.invalidateHaystacks()
        } catch {
            addError = "The copy was not saved: \(error.localizedDescription)"
        }
    }

    private func save() {
        try? modelContext.save()
    }

    /// The card becomes the picked product. Its printing stays when the new
    /// product has it, and the printing rules choose one when it does not.
    private func assign(_ picked: SearchHit) {
        guard picked.productId != card.productId else { return }
        try? CardEditor.assign(card, toProduct: picked.productId, context: modelContext)
        model.invalidateHaystacks()
        Task {
            await model.load(for: [card])
            let available = printings
            if !available.isEmpty, !available.contains(card.printing) {
                card.printing = PrintingRules.choose(available: available, rarity: picked.rarity, sessionDefault: nil).printing
                save()
            }
        }
    }

    /// Drops the catalog match and marks the card untracked. There is no
    /// scanned photo to carry over here — this card was already in
    /// inventory — so the photo, if he wants one, comes from `ManualIdentitySection`'s
    /// picker below.
    private func markSChinese() {
        let previousName = card.displayName(hit)
        card.productId = 0
        card.matchConfidence = .manual
        card.candidateProductIds = []
        card.language = "zh-Hans"
        if card.manualName.isEmpty { card.manualName = previousName ?? "" }
        save()
        model.invalidateHaystacks()
    }

    /// A box that produced nothing. Its line stays, ripped, at cost — the
    /// dud's loss the purchase-level rip performance already expects — and
    /// only the self-card that stood for it leaves.
    private func markNoHits() {
        let item = Allocation.ripTarget(for: card, context: modelContext)
        item.isRipped = true
        onDelete()
    }
}

/// The name, set, number, language, and value of a card with no catalog
/// product. He typed them, so he can correct them here.
struct ManualIdentitySection: View {
    let card: OwnedCard
    var onChange: () -> Void
    var onPhotoChanged: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @State private var valueText = ""
    @State private var pickedPhoto: PhotosPickerItem?

    /// A stored code that is not in the list still shows, so the picker never
    /// has a selection without a row.
    private var languageCodes: [String] {
        CardLanguage.codes.contains(card.language) ? CardLanguage.codes : CardLanguage.codes + [card.language]
    }

    var body: some View {
        Section {
            TextField("Name", text: binding(\.manualName))
                .textInputAutocapitalization(.words)
            TextField("Set", text: binding(\.manualSetName))
                .textInputAutocapitalization(.words)
            TextField("Number", text: binding(\.manualNumber))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Picker("Language", selection: binding(\.language)) {
                ForEach(languageCodes, id: \.self) { code in
                    Text(CardLanguage.name(code)).tag(code)
                }
            }
            MoneyField(label: "Value", text: $valueText)
        } header: {
            Text("The card")
        } footer: {
            Text("The catalog does not carry this card. The name and the value are yours. The app uses the value as the card's market value.")
        }
        .onAppear {
            valueText = card.manualMarketCents.map(Money.fieldText) ?? ""
        }
        .onChange(of: valueText) { _, text in
            // An unreadable value keeps the last good one.
            if text.isEmpty {
                card.manualMarketCents = nil
            } else if let cents = Money.cents(from: text) {
                card.manualMarketCents = cents
            }
            save()
        }
        if card.isSChinese {
            Section {
                PhotosPicker(card.photoURLString == nil ? "Choose a photo…" : "Change photo…", selection: $pickedPhoto, matching: .images)
                if card.photoURLString != nil {
                    Button("Remove photo", role: .destructive) {
                        CardPhotoStore.remove([card.id])
                        onPhotoChanged()
                    }
                }
            } footer: {
                Text("The catalog carries no art for this card. Its photo is yours: the one from the scan, or one you pick.")
            }
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data)?.cgImage,
                       let jpeg = CardPhotoStore.jpeg(image) {
                        try? CardPhotoStore.save(jpeg, for: card.id)
                        onPhotoChanged()
                    }
                    pickedPhoto = nil
                }
            }
        }
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<OwnedCard, String>) -> Binding<String> {
        Binding(get: { card[keyPath: keyPath] }, set: { card[keyPath: keyPath] = $0; save() })
    }

    private func save() {
        try? modelContext.save()
        onChange()
    }
}
