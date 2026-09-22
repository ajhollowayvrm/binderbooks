import SwiftData
import SwiftUI

/// The sold-orders files he picked, waiting for review.
struct PendingSalesFile: Identifiable {
    let id = UUID()
    var sources: SalesOrderSources.Result
}

/// Review a sold-orders file, then apply it to the books.
///
/// Nothing is saved until he taps Import. A removal starts switched off: the
/// app found the duplicate, and he decides.
struct SalesImportSheet: View {
    let sources: SalesOrderSources.Result

    private var contents: SalesOrderCSV.Contents { sources.contents }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(CatalogController.self) private var catalog
    @Query private var sales: [Sale]
    @Query private var cards: [OwnedCard]

    @State private var plan: SalesOrderImport.Plan?
    @State private var catalogMissing = false
    @State private var removing: Set<UUID> = []
    @State private var report: SalesOrderImport.Report?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let report {
                    List {
                        Section("Imported") { Text(report.summary) }
                    }
                } else if let failure {
                    ContentUnavailableView("The import stopped", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else if let plan {
                    planList(plan)
                } else {
                    ProgressView("Matching orders…")
                }
            }
            .navigationTitle("Import orders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(report == nil ? "Cancel" : "Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { run() }
                        .disabled(report != nil || !hasWork)
                }
            }
        }
        .interactiveDismissDisabled(plan != nil && report == nil)
        .task { await build() }
    }

    private var hasWork: Bool {
        guard let plan else { return false }
        return !plan.matches.isEmpty || !plan.newSales.isEmpty || !plan.cardsToAdd.isEmpty || !removing.isEmpty
    }

    // MARK: - Plan

    private func planList(_ plan: SalesOrderImport.Plan) -> some View {
        List {
            Section {
                LabeledContent("Orders in the files", value: "\(plan.orderCount)")
                LabeledContent("Already on your books", value: "\(plan.alreadyOnBooks)")
                LabeledContent("Matched to a sale", value: "\(plan.matches.count)")
                LabeledContent("New", value: "\(plan.newSales.count)")
                if plan.canceledNotOnBooks > 0 {
                    LabeledContent("Canceled, not on your books", value: "\(plan.canceledNotOnBooks)")
                }
                if !plan.cardsToAdd.isEmpty {
                    LabeledContent("Already on your books, cards to add", value: "\(plan.cardsToAdd.count)")
                }
                if !sources.ordersWithoutCards.isEmpty {
                    LabeledContent("Orders with no cards listed", value: "\(sources.ordersWithoutCards.count)")
                }
                if !plan.unreadableRows.isEmpty {
                    LabeledContent("Rows not read", value: plan.unreadableRows.map(\.label).joined(separator: ", "))
                }
            } footer: {
                if catalogMissing {
                    Text("The catalog is not installed, so no card can link to your inventory.")
                } else {
                    Text("A matched sale takes the order number. Its money does not change.")
                }
            }

            if !plan.channelCorrections.isEmpty {
                Section {
                    ForEach(plan.channelCorrections) { match in
                        LabeledContent {
                            Text("\(LedgerEntry.channelName(match.channelBefore ?? "")) → \(LedgerEntry.channelName(match.order.channel.rawValue))")
                        } label: {
                            Text(match.order.lines.first?.productName ?? match.order.orderId).lineLimit(1)
                            Text(match.order.soldAt.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                } header: {
                    Text("Channel corrected")
                } footer: {
                    Text("Your books file these sales under another channel. The file's channel replaces it.")
                }
            }

            if !plan.newSales.isEmpty {
                newSection(plan)
            }

            if !plan.cardsToAdd.isEmpty {
                cardsToAddSection(plan)
            }

            if !plan.removals.isEmpty {
                Section {
                    ForEach(plan.removals) { removal in
                        Toggle(isOn: removalBinding(removal.saleId)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(removal))
                                Text("\(removal.soldAt.formatted(date: .abbreviated, time: .omitted)) · \(LedgerEntry.channelName(removal.channelRaw)) · \(removal.grossCents.asCurrency)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                if !removal.describedAs.isEmpty {
                                    Text(removal.describedAs).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Remove from your books")
                } footer: {
                    Text("Nothing is removed unless you switch it on. A card on a removed sale goes back to inventory.")
                }
            }
        }
    }

    @ViewBuilder private func newSection(_ plan: SalesOrderImport.Plan) -> some View {
        let paid = plan.newSales.reduce(0) { $0 + $1.order.totalCents }
        let fees = plan.newSales.reduce(0) { $0 + $1.feeCents }
        let postage = plan.newSales.reduce(0) { $0 + $1.postageCents }
        let cardCount = plan.newSales.reduce(0) { $0 + $1.lines.count }
        let linked = plan.newSales.reduce(0) { $0 + $1.linkedCount }

        Section {
            LabeledContent("Buyers paid", value: paid.asCurrency)
            LabeledContent("Estimated fees", value: "−" + fees.asCurrency)
            LabeledContent("Estimated postage", value: "−" + postage.asCurrency)
            LabeledContent("Cards linked to inventory", value: "\(linked) of \(cardCount)")
            ForEach(plan.newSales) { sale in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(LedgerEntry.channelName(sale.order.channel.rawValue)) · \(sale.order.soldAt.formatted(date: .abbreviated, time: .omitted))")
                        Text(sale.lines.map(\.describedAs).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(sale.order.totalCents.asCurrency).monospacedDigit()
                        Text("\(sale.linkedCount) of \(sale.lines.count) linked")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("New orders")
        } footer: {
            Text("The file has no fees. The app estimates each order's fees and postage from your other orders on its channel, and marks the order estimated. A linked card is tagged sold.")
        }
    }

    @ViewBuilder private func cardsToAddSection(_ plan: SalesOrderImport.Plan) -> some View {
        let cardCount = plan.cardsToAdd.reduce(0) { $0 + $1.lines.count }
        let linked = plan.cardsToAdd.reduce(0) { $0 + $1.linkedCount }

        Section {
            LabeledContent("Cards linked to inventory", value: "\(linked) of \(cardCount)")
            ForEach(plan.cardsToAdd) { addition in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(LedgerEntry.channelName(addition.order.channel.rawValue)) · \(addition.order.soldAt.formatted(date: .abbreviated, time: .omitted))")
                        Text(addition.lines.map(\.describedAs).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Text("\(addition.linkedCount) of \(addition.lines.count) linked")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Cards for orders already on your books")
        } footer: {
            Text("These sales are on your books with no cards recorded — an order list imported without its pull sheet, or an order the pull sheet did not reach. The money on them does not change. A linked card is tagged sold.")
        }
    }

    private func title(_ removal: SalesOrderImport.Removal) -> String {
        switch removal.reason {
        case .canceled(let orderId): return "Canceled order \(orderId)"
        case .duplicate(let orderId): return "Second record of order \(orderId)"
        }
    }

    private func removalBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { removing.contains(id) },
            set: { on in
                if on { removing.insert(id) } else { removing.remove(id) }
            }
        )
    }

    // MARK: - Actions

    private func build() async {
        guard plan == nil else { return }
        var products: [SalesOrderCatalog.CopyKey: Int] = [:]
        if let database = catalog.database {
            let orders = contents.orders
            do {
                products = try await database.asyncRead { db in try SalesOrderCatalog.resolve(db, orders: orders) }
            } catch {
                failure = error.localizedDescription
                return
            }
        } else {
            catalogMissing = true
        }
        plan = SalesOrderImport.plan(contents, sales: sales, cards: cards, products: products)
    }

    private func run() {
        guard let plan else { return }
        do {
            report = try SalesOrderImport.apply(plan, removing: removing, context: modelContext)
        } catch {
            failure = error.localizedDescription
        }
    }
}
