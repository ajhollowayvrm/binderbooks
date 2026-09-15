import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Settings: the catalog, and the backup that stands between him and total loss.
/// Export is one tap; the file is prepared when the screen opens.
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var cards: [OwnedCard]
    @Query private var purchases: [Purchase]

    @State private var exportData: Data?
    @State private var exportError: String?
    @State private var showImporter = false
    @State private var pendingImport: CollectionExport.File?
    @State private var importError: String?
    @State private var importReport: CollectionExport.Report?
    @State private var showListingExport = false
    @State private var showSalesImporter = false
    @State private var pendingSales: PendingSalesFile?
    @State private var showListingImporter = false
    @State private var pendingListings: PendingListingsFile?
    @AppStorage("lastExportAt") private var lastExportAt: Double = 0
    @AppStorage(PPTKey.defaultsKey) private var pptKey = ""
    @AppStorage(SellingCostsKey.defaultsKey) private var costOverride = ""
    @AppStorage(InventorySort.defaultsKey) private var defaultSort: InventorySort = .newest
    @Query private var sales: [Sale]

    private var derivedRates: ChannelRates { ChannelRates.derived(from: sales) }

    var body: some View {
        List {
            Section("Catalog") {
                NavigationLink(value: AppRoute.catalogStatus) {
                    Label("Catalog status and updates", systemImage: "externaldrive")
                }
            }

            Section {
                Picker("Default sort", selection: $defaultSort) {
                    ForEach(InventorySort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
            } header: {
                Text("Inventory")
            } footer: {
                Text("The inventory page opens in this order. The sort button beside the chips changes the order until the app quits.")
            }

            Section {
                SecureField("API key", text: $pptKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("PokemonPriceTracker")
            } footer: {
                Text("Fetches graded comps onto cards. About two credits per card. Your own figures always win over fetched ones.")
            }

            feesSection

            Section {
                Button {
                    showListingExport = true
                } label: {
                    Label("List inventory on TCGplayer", systemImage: "tablecells")
                }
                .sheet(isPresented: $showListingExport) {
                    TCGplayerExportSheet()
                }
                Button {
                    showListingImporter = true
                } label: {
                    Label("Import TCGplayer listings", systemImage: "tray.and.arrow.down")
                }
                .fileImporter(isPresented: $showListingImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
                    handleListingImport(result)
                }
                .sheet(item: $pendingListings) { file in
                    TCGplayerListingImportSheet(contents: file.contents)
                }
            } header: {
                Text("TCGplayer")
            } footer: {
                Text("List builds the CSV that Seller Portal imports, with each card at the cheapest live listing of its condition and printing. Import reads Seller Portal's pricing export and puts the stock you list into inventory, tagged listed.")
            }

            Section {
                Button {
                    showSalesImporter = true
                } label: {
                    Label("Import sold orders", systemImage: "cart.badge.plus")
                }
                .fileImporter(isPresented: $showSalesImporter, allowedContentTypes: [.commaSeparatedText, .plainText], allowsMultipleSelection: true) { result in
                    handleSalesImport(result)
                }
                .sheet(item: $pendingSales) { file in
                    SalesImportSheet(contents: file.contents)
                }
            } header: {
                Text("Orders")
            } footer: {
                Text("Pick TCGplayer's order list and pull sheet together, from Orders, Export Orders and Export Pull Sheet. A Sold Items CSV, with or without eBay rows, also works on its own. You review every change before the app saves it.")
            }

            Section {
                if let exportData {
                    Button {
                        shareExport(exportData)
                    } label: {
                        Label("Export collection (\(exportData.count.formatted(.byteCount(style: .file))))", systemImage: "square.and.arrow.up")
                    }
                } else if exportError == nil {
                    ProgressView()
                }
                if let exportError {
                    Text(exportError).foregroundStyle(.red)
                }
                Button {
                    showImporter = true
                } label: {
                    Label("Import collection", systemImage: "square.and.arrow.down")
                }
                if lastExportAt > 0 {
                    LabeledContent("Last export", value: Date(timeIntervalSince1970: lastExportAt).formatted(date: .abbreviated, time: .shortened))
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("There is no sync and no cloud backup. The export holds the whole collection store: \(purchases.count) purchases and \(cards.count) cards. The catalog is not included; it downloads again.")
            }

            if let importError {
                Section { Text(importError).foregroundStyle(.red) }
            }
            if let importReport {
                Section("Last import") {
                    Text(importReport.summary)
                        .font(.footnote)
                }
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                LabeledContent("Export format", value: "\(CollectionExport.format) v\(CollectionExport.version)")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: cards.count + purchases.count) {
            prepareExport()
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            handleImport(result)
        }
        .sheet(item: $pendingImport) { file in
            ImportConfirmSheet(file: file) { mode in
                run(file, mode: mode)
            }
        }
    }

    /// What selling a card costs him, for the grading projection on the ledger's
    /// Summary tab.
    ///
    /// The rates come from his own orders, so there is nothing to type and they
    /// correct themselves as he sells. The one field overrides the blend when he
    /// knows better — a slab sells on eBay whatever his singles do.
    @ViewBuilder private var feesSection: some View {
        let rates = derivedRates

        Section {
            if rates.isEmpty {
                Text("No orders yet, so there is no rate to read.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rates.rows) { row in
                    LabeledContent(row.name) {
                        Text("\(SellingCostsKey.fieldText(row.feeBasisPoints))% · \(row.orderCount) \(row.orderCount == 1 ? "order" : "orders")")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Shipping you pay") {
                    Text("\(SellingCostsKey.fieldText(rates.shippingBasisPoints))%")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Rate for projections")
                Spacer()
                TextField(SellingCostsKey.fieldText(rates.totalBasisPoints), text: $costOverride)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospacedDigit())
                    .frame(maxWidth: 90)
                Text("%").foregroundStyle(.secondary)
            }
        } header: {
            Text("Fees")
        } footer: {
            Text("Read from your own orders. Fees and shipping together come to \(SellingCostsKey.fieldText(rates.totalBasisPoints))%, which the grading projection uses. Type a rate to override it; clear the field to go back.")
        }
    }

    private func prepareExport() {
        do {
            exportData = try CollectionExport.exportData(modelContext)
            exportError = nil
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// Opens the system share sheet on the export file.
    ///
    /// The last export time moves only when the sheet reports a completed action.
    /// A cancelled sheet or a closed preview is not a backup.
    private func shareExport(_ data: Data) {
        exportError = nil
        do {
            let url = URL.temporaryDirectory.appending(path: CollectionExport.suggestedFileName())
            try data.write(to: url, options: .atomic)
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            sheet.completionWithItemsHandler = { _, completed, _, _ in
                if completed { lastExportAt = Date().timeIntervalSince1970 }
            }
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            var presenter = scene?.keyWindow?.rootViewController
            while let presented = presenter?.presentedViewController { presenter = presented }
            guard let presenter else { return }
            sheet.popoverPresentationController?.sourceView = presenter.view
            presenter.present(sheet, animated: true)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        importError = nil
        importReport = nil
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            pendingImport = try CollectionExport.decode(data)
        } catch {
            importError = error.localizedDescription
        }
    }

    /// One file is a Sold Items CSV. Two files are TCGplayer's order list and
    /// pull sheet, picked in either order.
    private func handleSalesImport(_ result: Result<[URL], Error>) {
        importError = nil
        do {
            let texts = try result.get().map { url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try String(contentsOf: url, encoding: .utf8)
            }
            switch texts.count {
            case 1:
                pendingSales = PendingSalesFile(contents: try SalesOrderCSV.read(texts[0]))
            case 2:
                guard let list = texts.first(where: { TCGplayerOrderExports.kind(of: $0) == .orderList }),
                      let sheet = texts.first(where: { TCGplayerOrderExports.kind(of: $0) == .pullSheet })
                else { throw TCGplayerOrderExports.JoinError.notTheTwoFiles }
                pendingSales = PendingSalesFile(contents: try TCGplayerOrderExports.join(orderList: list, pullSheet: sheet).contents)
            default:
                throw TCGplayerOrderExports.JoinError.notTheTwoFiles
            }
        } catch {
            importError = error.localizedDescription
        }
    }

    private func handleListingImport(_ result: Result<URL, Error>) {
        importError = nil
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            pendingListings = PendingListingsFile(contents: try TCGplayerPricingCSV.read(text))
        } catch {
            importError = error.localizedDescription
        }
    }

    private func run(_ file: CollectionExport.File, mode: CollectionExport.Mode) {
        do {
            importReport = try CollectionExport.apply(file, to: modelContext, mode: mode)
            prepareExport()
        } catch {
            importError = error.localizedDescription
        }
    }
}

extension CollectionExport.File: Identifiable {
    var id: String { exportedAt }
}

/// Merge or replace. Replace is destructive, so it asks twice.
struct ImportConfirmSheet: View {
    let file: CollectionExport.File
    var onRun: (CollectionExport.Mode) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmReplace = false

    var body: some View {
        NavigationStack {
            List {
                Section("File") {
                    LabeledContent("Exported", value: file.exportedAt)
                    Text(file.counts)
                }
                Section {
                    Button {
                        onRun(.merge)
                        dismiss()
                    } label: {
                        Label("Merge into this device", systemImage: "arrow.triangle.merge")
                    }
                    Button(role: .destructive) {
                        confirmReplace = true
                    } label: {
                        Label("Replace everything on this device", systemImage: "arrow.counterclockwise")
                    }
                } footer: {
                    Text("Merge updates rows with the same id and adds the rest. Replace deletes the store first, so the file becomes the whole collection.")
                }
            }
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .confirmationDialog("Delete everything on this device and load the file?", isPresented: $confirmReplace, titleVisibility: .visible) {
                Button("Replace", role: .destructive) {
                    onRun(.replace)
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium])
    }
}
