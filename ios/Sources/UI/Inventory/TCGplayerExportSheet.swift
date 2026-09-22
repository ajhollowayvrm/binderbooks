import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Pick cards, price them against TCGplayer, and share the Seller Portal CSV.
///
/// The pricing export from Seller Portal comes first. It says what TCGplayer
/// lists now, and each row of the file adds the copies he holds less that
/// stock. See `TCGplayerListingExport`.
///
/// Every inventory card that can be listed is on the list and starts ticked.
/// An unticked card leaves its SKU alone on TCGplayer. The cards that cannot
/// be listed show as a count for each reason, so no card leaves the file in
/// silence.
struct TCGplayerExportSheet: View {
    /// The cards to tick at the start. Nil ticks every listable card.
    var preselected: Set<UUID>?

    private typealias Export = TCGplayerListingExport

    @Environment(\.dismiss) private var dismiss
    @Environment(CatalogController.self) private var catalog
    @Environment(InventoryModel.self) private var model
    @Query(sort: \OwnedCard.acquiredAt, order: .reverse) private var cards: [OwnedCard]
    @AppStorage(TCGplayerListingExport.shippingDefaultsKey) private var shippingText = ""
    @AppStorage(MasterSetHold.defaultsKey) private var masterSetGroups = ""
    @AppStorage(TCGplayerListingExport.floorDefaultsKey) private var floorText = Money.fieldText(TCGplayerListingExport.defaultFloorCents)

    @State private var selection: Set<UUID> = []
    @State private var didSeed = false
    @State private var builder = TCGplayerListingBuilder()
    @State private var run: Task<Void, Never>?
    @State private var outcome: TCGplayerListingBuilder.Outcome?
    @State private var categoryNames: [Int: String] = [:]
    @State private var pickingStock = false
    @State private var checking = false
    /// What TCGplayer lists now. Nil until he picks the pricing export.
    @State private var stock: Export.Stock?
    /// The SKUs whose stock comes off, by SKU id.
    @State private var removalSelection: Set<Int> = []
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

    /// What he typed, or the rule's own figure while the field is empty or
    /// half typed.
    private var floorCents: Int { Money.cents(from: floorText) ?? TCGplayerListingExport.defaultFloorCents }

    private var removals: (remove: [TCGplayerPricingCSV.Row], unsure: [TCGplayerPricingCSV.Row]) {
        guard let stock else { return ([], []) }
        return Export.removals(stock, rows: rows, prices: model.prices)
    }

    /// The SKU's row in the pricing export, for the pick list.
    private func stockRow(for row: InventoryRow) -> TCGplayerPricingCSV.Row? {
        guard let stock, let hit = row.hit,
              let printing = Export.printing(for: row.card, prices: model.prices[hit.productId] ?? []) else { return nil }
        return stock.row(for: .init(productId: hit.productId, condition: row.card.condition, printing: printing, language: Export.language(categoryId: hit.categoryId)))
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
                        checking ? "Reading…" : (stock == nil ? "Pick the pricing export…" : "Pick it again…"),
                        systemImage: "doc.text"
                    )
                }
                .disabled(checking || builder.isRunning)
                if let stock {
                    LabeledContent("SKUs TCGplayer lists", value: "\(stock.rows.values.filter { $0.line.quantity > 0 }.count)")
                    if !stock.unmatched.isEmpty {
                        LabeledContent("TCGplayer rows not matched", value: "\(stock.unmatched.count)")
                    }
                    if !stock.unreadableRows.isEmpty {
                        LabeledContent("Rows not read", value: "\(stock.unreadableRows.count)")
                    }
                }
                if let checkError {
                    Text(checkError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("What TCGplayer lists now")
            } footer: {
                Text("In Seller Portal, export your pricing file, then pick it here. Each row of the upload adds the copies you hold less the copies TCGplayer lists: one held and one listed adds 0 and only changes the price. TCGplayer takes a card off its stock when a buyer pays, so import your sold orders first. A row TCGplayer does not match stays as it is.")
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
                moneyRow("Shipping you charge", text: $shippingText)
                moneyRow("Leave out under", text: $floorText)
            } footer: {
                Text("A card worth \(ProductPrice.marketRuleCents.asCurrency) or more lists at its market price. A cheaper card lists at the cheapest live listing of the same condition and printing, plus that listing's shipping, less what you charge to ship. A card whose cheapest listing is under \(floorCents.asCurrency) stays out of the file. A card nobody sells takes its market price.")
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
                                if stock != nil {
                                    let listed = stockRow(for: row)
                                    Text("TCGplayer lists \(listed?.line.quantity ?? 0)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
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

            if stock != nil {
                removalSection
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

    /// SKUs TCGplayer lists that no listable card fills. Their rows take the
    /// stock off, so he checks each one.
    @ViewBuilder
    private var removalSection: some View {
        let removals = self.removals
        if !removals.remove.isEmpty {
            Section {
                ForEach(removals.remove) { row in
                    Button {
                        if removalSelection.contains(row.skuId) { removalSelection.remove(row.skuId) } else { removalSelection.insert(row.skuId) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: removalSelection.contains(row.skuId) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(removalSelection.contains(row.skuId) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                            stockRowLabel(row, trailing: "−\(row.line.quantity)")
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(builder.isRunning)
                }
            } header: {
                Text("Take off TCGplayer: \(removalSelection.intersection(removals.remove.map(\.skuId)).count) of \(removals.remove.count)")
                    .textCase(nil)
            } footer: {
                Text("TCGplayer lists these and you hold no listable copy. A card you sold, graded, or moved to your personal collection lands here. Untick a row to leave it on TCGplayer.")
            }
        }
        if !removals.unsure.isEmpty {
            Section {
                ForEach(removals.unsure) { row in
                    stockRowLabel(row, trailing: "\(row.line.quantity)")
                }
            } header: {
                Text("Left on TCGplayer, check by hand")
                    .textCase(nil)
            } footer: {
                Text("You hold a copy of these cards with no printing chosen, so the app cannot tell which SKU it is. Choose the printing to include them.")
            }
        }
    }

    private func stockRowLabel(_ row: TCGplayerPricingCSV.Row, trailing: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.line.productName)
                    .lineLimit(1)
                Text("\(row.line.setName) · \(row.line.condition)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(trailing)
                .font(.body.monospacedDigit())
        }
    }

    private func moneyRow(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("$").foregroundStyle(.secondary)
            TextField("0.00", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .frame(maxWidth: 80)
        }
    }

    private func buildBar(selected: [InventoryRow]) -> some View {
        let removing = removalSelection.intersection(removals.remove.map(\.skuId)).count
        return VStack(spacing: 6) {
            if builder.isRunning {
                ProgressView(value: Double(builder.done), total: Double(max(1, builder.total)))
                Text("Pricing \(builder.done) of \(builder.total)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button {
                start(selected)
            } label: {
                Text(builder.isRunning ? "Pricing…" : (stock == nil ? "Pick the pricing export first" : "Price \(selected.count) \(selected.count == 1 ? "card" : "cards")"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(stock == nil || (selected.isEmpty && removing == 0) || builder.isRunning)
        }
        .padding()
        .background(.bar)
    }

    // MARK: - Result

    private func resultList(_ outcome: TCGplayerListingBuilder.Outcome) -> some View {
        let name = Export.suggestedFileName()
        let removing = removals.remove.filter { removalSelection.contains($0.skuId) }
        let file = CSVFile(text: Export.csv(outcome.rows, removals: removing, categoryNames: categoryNames), name: name)
        let rowCount = outcome.rows.count + removing.count
        let listedBefore = outcome.rows.filter(\.line.listedBefore).count
        return List {
            Section {
                Text(outcome.report.summary)
                    .font(.footnote)
                if listedBefore > 0 {
                    Label("\(listedBefore) \(listedBefore == 1 ? "row lists a SKU" : "rows list SKUs") TCGplayer sold out of. If one of those sold and is not marked sold, import your sold orders first.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if rowCount > 0 {
                    ShareLink(item: file, preview: SharePreview(name, image: Image(systemName: "tablecells"))) {
                        Label("Share CSV (\(rowCount) rows)", systemImage: "square.and.arrow.up")
                    }
                }
            } footer: {
                Text("In Seller Portal, open Inventory and choose Import Inventory. Check the staged inventory before it goes live. Each row adds the copies you hold less the copies TCGplayer lists, so the upload leaves TCGplayer at what you hold. Export a new pricing file before the next upload.")
            }

            if !outcome.rows.isEmpty {
                Section("Rows") {
                    ForEach(outcome.rows) { row in
                        pricedRow(row)
                    }
                }
            }
            if !removing.isEmpty {
                Section("Taken off TCGplayer") {
                    ForEach(removing) { row in
                        stockRowLabel(row, trailing: "−\(row.line.quantity)")
                    }
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
                Text("\(Export.conditionText(row.line.key)) · hold \(row.line.quantity), TCGplayer lists \(row.line.listed)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.line.addQuantity > 0 ? "+\(row.line.addQuantity)" : "\(row.line.addQuantity)")
                    .font(.body.monospacedDigit().bold())
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
            selection = Set(listable.map(\.card.id))
        }
        selection.subtract(wholeHeld(listable, held: held))
    }

    /// Reads the hold switch again over the ticks he has now. Turning the hold
    /// on unticks the copies it keeps. Turning it off ticks them.
    private func applyHold() {
        let listable = listableRows
        if holdBack {
            selection.subtract(wholeHeld(listable, held: held))
        } else {
            let groups = MasterSetHold.ids(masterSetGroups)
            let heldBefore = MasterSetHold.keep(from: rows, prices: model.prices, groups: groups)
            let back = listable.filter { heldBefore.contains($0.card.id) && $0.card.quantity <= 1 }
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
        guard let stock else { return }
        let plan = Export.plan(selected, prices: model.prices, holdingOne: holdingOne, stock: stock)
        let shipping = Money.cents(from: shippingText) ?? 0
        run = Task {
            let result = await builder.build(plan, shippingChargedCents: shipping, market: TCGplayerMarketClient(), floorCents: floorCents)
            if !Task.isCancelled { outcome = result }
        }
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
                checkError = "Install the catalog first. The app matches each TCGplayer row to a catalog card."
                return
            }
            let rows = contents.rows + contents.emptyRows
            let products = try await database.asyncRead { db in try TCGplayerPricingCSV.products(db, rows: rows) }
            let read = Export.stock(contents, products: products)
            stock = read
            // A single card picked from inventory must not take the whole
            // store's stock off, so those rows start unticked there.
            removalSelection = preselected == nil ? Set(Export.removals(read, rows: self.rows, prices: model.prices).remove.map(\.skuId)) : []
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
