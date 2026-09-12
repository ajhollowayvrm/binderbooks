import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Pick cards, price them against TCGplayer, and share the Seller Portal CSV.
///
/// Every inventory card that can be listed is on the list. A card tagged
/// `listed` starts unticked, because the import adds quantity and a second
/// upload lists the card twice. The cards that cannot be listed show as a count
/// for each reason, so no card leaves the file in silence.
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

    @State private var selection: Set<UUID> = []
    @State private var didSeed = false
    @State private var builder = TCGplayerListingBuilder()
    @State private var run: Task<Void, Never>?
    @State private var outcome: TCGplayerListingBuilder.Outcome?
    @State private var categoryNames: [Int: String] = [:]
    @State private var taggedCount: Int?

    /// Sold cards are already gone from these rows.
    private var rows: [InventoryRow] { model.rows(from: cards, applyFilter: false) }

    private var listableRows: [InventoryRow] {
        rows.filter { Export.skipReason(for: $0, prices: model.prices) == nil }
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
        .interactiveDismissDisabled(builder.isRunning)
        .onAppear { seed() }
        .onDisappear { run?.cancel() }
        .task(id: catalog.database?.path) { await loadCategories() }
    }

    // MARK: - Pick

    private var pickList: some View {
        let listable = listableRows
        let skipped = skippedCounts
        let allTicked = !listable.isEmpty && listable.allSatisfy { selection.contains($0.card.id) }
        return List {
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
                Text("Each card is priced at the cheapest live listing of the same condition and printing, plus that listing's shipping, less what you charge to ship. A card nobody sells takes its market price.")
            }

            Section {
                ForEach(listable) { row in
                    Button {
                        toggle(row.card.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selection.contains(row.card.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection.contains(row.card.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                            OwnedCardRow(row: row)
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
                        selection = allTicked ? [] : Set(listable.map(\.card.id))
                    }
                    .font(.caption)
                    .disabled(listable.isEmpty || builder.isRunning)
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
                    Button {
                        tagListed(cardIds)
                    } label: {
                        Label(taggedCount.map { "Tagged \($0) cards listed" } ?? "Tag these \(cardIds.count) cards listed", systemImage: "tag")
                    }
                    .disabled(taggedCount != nil)
                }
            } footer: {
                Text("In Seller Portal, open Inventory and choose Import Inventory. Check the staged inventory before it goes live. The import adds to the quantity you already list.")
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
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func start(_ selected: [InventoryRow]) {
        let plan = Export.plan(selected, prices: model.prices)
        let shipping = Money.cents(from: shippingText) ?? 0
        run = Task {
            let result = await builder.build(plan, shippingChargedCents: shipping, market: TCGplayerMarketClient())
            if !Task.isCancelled { outcome = result }
        }
    }

    private func tagListed(_ ids: [UUID]) {
        let wanted = Set(ids)
        let tagged = cards.filter { wanted.contains($0.id) }
        CardTagEditor(context: modelContext).add(ReservedTag.listed, to: tagged)
        taggedCount = tagged.count
        onTagged()
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
