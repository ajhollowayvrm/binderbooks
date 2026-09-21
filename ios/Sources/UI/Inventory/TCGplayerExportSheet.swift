import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Pick cards, price them against TCGplayer, and share the Seller Portal CSV.
///
/// Every inventory card that can be listed is on the list. A card tagged
/// `listed` starts unticked, because the import adds quantity and a second
/// upload lists the card twice. The cards in the file take the tag when the
/// file is made. The cards that cannot be listed show as a count for each
/// reason, so no card leaves the file in silence.
///
/// "Check against TCGplayer" reads the pricing export first. It tags the cards
/// he listed by hand and unticks the ones that may have sold. See
/// `TCGplayerStockCheck`.
struct TCGplayerExportSheet: View {
    /// The cards to tick at the start. Nil ticks every listable card that is
    /// not already tagged `listed`.
    var preselected: Set<UUID>?
    var onTagged: () -> Void = {}

    private typealias Export = TCGplayerListingExport

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(CatalogController.self) private var catalog
    @Environment(InventoryModel.self) private var model
    @Query(sort: \OwnedCard.acquiredAt, order: .reverse) private var cards: [OwnedCard]
    @AppStorage(TCGplayerListingExport.shippingDefaultsKey) private var shippingText = ""
    @AppStorage(MasterSetHold.defaultsKey) private var masterSetGroups = ""

    @State private var selection: Set<UUID> = []
    @State private var didSeed = false
    @State private var builder = TCGplayerListingBuilder()
    @State private var run: Task<Void, Never>?
    @State private var outcome: TCGplayerListingBuilder.Outcome?
    @State private var categoryNames: [Int: String] = [:]
    @State private var taggedCount: Int?
    /// The cards this export tagged, so Undo takes the tag off only those.
    @State private var taggedIds: [UUID] = []
    @State private var pickingStock = false
    @State private var checking = false
    @State private var stockCheck: TCGplayerStockCheck.Result?
    @State private var stockTagged = 0
    @State private var checkError: String?
    /// On by default, because the set flag already says he is master setting.
    /// He turns it off to list every copy for one run.
    @State private var holdBack = true

    /// Sold cards are already gone from these rows.
    private var rows: [InventoryRow] { model.rows(from: cards, applyFilter: false) }

    private var listableRows: [InventoryRow] {
        rows.filter { Export.skipReason(for: $0, prices: model.prices) == nil }
    }

    /// The copies that stay for a master set. Empty when he turns the hold
    /// off, or when no card in the export belongs to a set he is building.
    private var held: Set<UUID> {
        holdBack ? MasterSetHold.keep(from: rows, prices: model.prices, groups: MasterSetHold.ids(masterSetGroups)) : []
    }

    /// The held cards that hold their only copy. A bulk card keeps one copy
    /// and lists the rest, so it stays ticked.
    private func wholeHeld(_ rows: [InventoryRow], held: Set<UUID>) -> Set<UUID> {
        Set(rows.filter { held.contains($0.card.id) && $0.card.quantity <= 1 }.map(\.card.id))
    }

    /// True when the export carries a card from a set he is master setting.
    private var touchesMasterSet: Bool {
        let groups = MasterSetHold.ids(masterSetGroups)
        guard !groups.isEmpty else { return false }
        return rows.contains { $0.hit.map { groups.contains($0.groupId) } ?? false }
    }

    private var skippedCounts: [(reason: Export.SkipReason, count: Int)] {
        var counts: [Export.SkipReason: Int] = [:]
        for row in rows {
            if let reason = Export.skipReason(for: row, prices: model.prices) { counts[reason, default: 0] += 1 }
        }
        return Export.SkipReason.allCases.compactMap { reason in counts[reason].map { (reason, $0) } }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let outcome {
                    resultList(outcome)
                } else {
                    pickList
                }
            }
            .navigationTitle("List on TCGplayer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(outcome == nil ? "Cancel" : "Done") {
                        run?.cancel()
                        dismiss()
                    }
                }
            }
        }
        // The pick list says "Kept for the master set" on the row itself, so
        // the inventory mark would say it twice.
        .environment(\.masterSetHeld, [])
        .interactiveDismissDisabled(builder.isRunning)
        .onAppear { seed() }
        .onChange(of: holdBack) { _, _ in applyHold() }
        .fileImporter(isPresented: $pickingStock, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            Task { await checkStock(result) }
        }
        .onDisappear { run?.cancel() }
        .task(id: catalog.database?.path) { await loadCategories() }
    }

    // MARK: - Pick

    private var pickList: some View {
        let listable = listableRows
        let skipped = skippedCounts
        let held = self.held
        let whole = wholeHeld(listable, held: held)
        let tickable = listable.filter { !whole.contains($0.card.id) }
        let allTicked = !tickable.isEmpty && tickable.allSatisfy { selection.contains($0.card.id) }
        return List {
            Section {
                Button {
                    pickingStock = true
                } label: {
                    Label(
                        checking ? "Checking…" : (stockCheck == nil ? "Check against TCGplayer…" : "Check again…"),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(checking || builder.isRunning)
                if let stockCheck {
                    LabeledContent("Listed by hand, now tagged", value: "\(stockTagged)")
                    LabeledContent("Was on TCGplayer, check", value: "\(stockCheck.toCheck.count)")
                    LabeledContent("Sold on TCGplayer", value: "\(stockCheck.soldOnTCGplayer)")
                    if stockCheck.unmatchedRows > 0 {
                        LabeledContent("TCGplayer rows not matched", value: "\(stockCheck.unmatchedRows)")
                    }
                }
                if let checkError {
                    Text(checkError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("In Seller Portal, export your pricing file, then pick it here. TCGplayer takes a card off its stock when a buyer pays, so open orders count. A card TCGplayer listed before and has no stock for now stays unticked.")
            }

            if touchesMasterSet {
                Section {
                    Toggle("Keep one of each card", isOn: $holdBack)
                        .disabled(builder.isRunning)
                } footer: {
                    Text(holdBack
                         ? "You are master setting a set in this export. \(held.count) \(held.count == 1 ? "copy stays" : "copies stay") out of the file, one for each card and printing. A card you also hold as a slab or in your personal collection keeps nothing back. Turn this off to list every copy."
                         : "Every copy goes in the file, including the cards of the set you are master setting.")
                }
            }

            Section {
                HStack {
                    Text("Shipping you charge")
                    Spacer()
                    Text("$").foregroundStyle(.secondary)
                    TextField("0.00", text: $shippingText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospacedDigit())
                        .frame(maxWidth: 80)
                }
            } footer: {
                Text("A card worth $5 or more lists at its market price. A cheaper card lists at the cheapest live listing of the same condition and printing, plus that listing's shipping, less what you charge to ship. A card whose cheapest listing is under $0.20 stays out of the file. A card nobody sells takes its market price.")
            }

            Section {
                ForEach(listable) { row in
                    Button {
                        toggle(row.card.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selection.contains(row.card.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection.contains(row.card.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                            VStack(alignment: .leading, spacing: 2) {
                                OwnedCardRow(row: row)
                                if held.contains(row.card.id) {
                                    Label(row.card.quantity > 1 ? "One copy stays for the master set" : "Kept for the master set", systemImage: "star.fill")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                }
                                if stockCheck?.toCheck.contains(row.card.id) == true {
                                    Label("Was on TCGplayer. Check that you still have it.", systemImage: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(builder.isRunning)
                }
            } header: {
                HStack {
                    Text("\(selection.count) of \(listable.count) selected")
                    Spacer()
                    Button(allTicked ? "None" : "All") {
                        selection = allTicked ? [] : Set(tickable.map(\.card.id))
                    }
                    .font(.caption)
                    .disabled(tickable.isEmpty || builder.isRunning)
                }
                .textCase(nil)
            }

            if !skipped.isEmpty {
                Section("Not listed") {
                    ForEach(skipped, id: \.reason) { item in
                        LabeledContent(item.reason.rawValue.prefix(1).uppercased() + item.reason.rawValue.dropFirst(), value: "\(item.count)")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            buildBar(selected: listable.filter { selection.contains($0.card.id) })
        }
    }

    private func buildBar(selected: [InventoryRow]) -> some View {
        VStack(spacing: 6) {
            if builder.isRunning {
                ProgressView(value: Double(builder.done), total: Double(max(1, builder.total)))
                Text("Pricing \(builder.done) of \(builder.total)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button {
                start(selected)
            } label: {
                Text(builder.isRunning ? "Pricing…" : "Price \(selected.count) \(selected.count == 1 ? "card" : "cards")")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selected.isEmpty || builder.isRunning)
        }
        .padding()
        .background(.bar)
    }

    // MARK: - Result

    private func resultList(_ outcome: TCGplayerListingBuilder.Outcome) -> some View {
        let name = Export.suggestedFileName()
        let file = CSVFile(text: Export.csv(outcome.rows, categoryNames: categoryNames), name: name)
        let cardIds = outcome.rows.flatMap(\.line.cardIds)
        return List {
            Section {
                Text(outcome.report.summary)
                    .font(.footnote)
                if !outcome.rows.isEmpty {
                    ShareLink(item: file, preview: SharePreview(name, image: Image(systemName: "tablecells"))) {
                        Label("Share CSV (\(outcome.rows.count) rows)", systemImage: "square.and.arrow.up")
                    }
                    if let taggedCount {
                        HStack {
                            Label("Tagged \(taggedCount) cards listed", systemImage: "tag")
                            Spacer()
                            Button("Undo") { undoTags() }
                                .buttonStyle(.borderless)
                        }
                    } else {
                        Button {
                            tagListed(cardIds)
                        } label: {
                            Label("Tag these \(cardIds.count) cards listed", systemImage: "tag")
                        }
                    }
                }
            } footer: {
                Text("In Seller Portal, open Inventory and choose Import Inventory. Check the staged inventory before it goes live. The import adds to the quantity you already list. The cards in this file are tagged listed, so they are not offered again. If you do not upload the file, tap Undo.")
            }

            Section("Rows") {
                ForEach(outcome.rows) { row in
                    pricedRow(row)
                }
            }
        }
    }

    private func pricedRow(_ row: Export.Priced) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.line.hit.name)
                    .lineLimit(1)
                Text(row.line.hit.setName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(Export.conditionText(row.line.key)) · ×\(row.line.quantity)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.priceCents.asCurrency)
                    .font(.body.monospacedDigit())
                Text(sourceText(row))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sourceText(_ row: Export.Priced) -> String {
        switch row.source {
        case .liveLow:
            return row.lowest.map { "low \($0.priceCents.asCurrency) + \($0.shippingCents.asCurrency) ship" } ?? "cheapest listing"
        case .market:
            return "market, no listings"
        case .atMarket:
            return "market, $5 and up"
        }
    }

    // MARK: - Actions

    private func seed() {
        guard !didSeed else { return }
        didSeed = true
        let listable = listableRows
        if let preselected {
            selection = Set(listable.map(\.card.id)).intersection(preselected)
        } else {
            selection = Set(listable.filter { !CardTagIndex.has(ReservedTag.listed, on: $0.card) }.map(\.card.id))
        }
        selection.subtract(wholeHeld(listable, held: held))
    }

    /// Reads the hold switch again over the ticks he has now. Turning the hold
    /// on unticks the copies it keeps. Turning it off ticks them, unless they
    /// already carry the `listed` tag.
    private func applyHold() {
        let listable = listableRows
        if holdBack {
            selection.subtract(wholeHeld(listable, held: held))
        } else {
            let groups = MasterSetHold.ids(masterSetGroups)
            let heldBefore = MasterSetHold.keep(from: rows, prices: model.prices, groups: groups)
            let back = listable.filter {
                heldBefore.contains($0.card.id) && $0.card.quantity <= 1
                    && !CardTagIndex.has(ReservedTag.listed, on: $0.card)
            }
            selection.formUnion(back.map(\.card.id))
        }
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func start(_ selected: [InventoryRow]) {
        // A ticked card he holds for the master set is a bulk card: it lists
        // every copy but one. A card he ticked by hand overrides the hold.
        let held = self.held
        let holdingOne = Set(selected.filter { held.contains($0.card.id) && $0.card.quantity > 1 }.map(\.card.id))
        let plan = Export.plan(selected, prices: model.prices, holdingOne: holdingOne)
        let shipping = Money.cents(from: shippingText) ?? 0
        run = Task {
            let result = await builder.build(plan, shippingChargedCents: shipping, market: TCGplayerMarketClient())
            if !Task.isCancelled {
                outcome = result
                // Tagged now, not after he taps a button. A card in the file
                // that stays untagged is offered again, and sold twice.
                tagListed(result.rows.flatMap(\.line.cardIds))
            }
        }
    }

    /// Only the cards with no tag yet, so Undo leaves an older tag alone.
    private func tagListed(_ ids: [UUID]) {
        let wanted = Set(ids)
        let newly = cards.filter { wanted.contains($0.id) && !CardTagIndex.has(ReservedTag.listed, on: $0) }
        CardTagEditor(context: modelContext).add(ReservedTag.listed, to: newly)
        taggedIds = newly.map(\.id)
        taggedCount = newly.count
        onTagged()
    }

    private func undoTags() {
        let wanted = Set(taggedIds)
        CardTagEditor(context: modelContext).remove(ReservedTag.listed, from: cards.filter { wanted.contains($0.id) })
        taggedIds = []
        taggedCount = nil
        onTagged()
    }

    private func checkStock(_ result: Result<URL, Error>) async {
        checkError = nil
        checking = true
        defer { checking = false }
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            let text: String
            do {
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                text = try String(contentsOf: url, encoding: .utf8)
            }
            let contents = try TCGplayerPricingCSV.read(text)
            guard let database = catalog.database else {
                checkError = "Install the catalog first. The check matches each TCGplayer row to a catalog card."
                return
            }
            let rows = contents.rows + contents.emptyRows
            let products = try await database.asyncRead { db in try TCGplayerPricingCSV.products(db, rows: rows) }
            let check = TCGplayerStockCheck.check(contents, cards: cards, products: products)
            let toTag = Set(check.toTag)
            let handListed = cards.filter { toTag.contains($0.id) }
            CardTagEditor(context: modelContext).add(ReservedTag.listed, to: handListed)
            stockTagged = handListed.count
            selection.subtract(toTag)
            selection.subtract(check.toCheck)
            stockCheck = check
            onTagged()
        } catch {
            checkError = error.localizedDescription
        }
    }

    private func loadCategories() async {
        guard let db = catalog.database, let all = try? await CatalogSearch(database: db).categories() else { return }
        categoryNames = Dictionary(all.map { ($0.categoryId, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}

struct CSVFile: Transferable {
    var text: String
    var name: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { Data($0.text.utf8) }
            .suggestedFileName { $0.name }
    }
}
