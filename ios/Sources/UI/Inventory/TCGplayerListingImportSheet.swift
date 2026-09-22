import SwiftData
import SwiftUI

/// A pricing export waiting for review.
struct PendingListingsFile: Identifiable {
    let id = UUID()
    var contents: TCGplayerPricingCSV.Contents
}

/// Review the stock a TCGplayer pricing export lists, then bring it onto the
/// inventory with the `listed` tag.
///
/// Nothing is saved until he taps Import.
struct TCGplayerListingImportSheet: View {
    let contents: TCGplayerPricingCSV.Contents

    private typealias Import = TCGplayerListingImport

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(CatalogController.self) private var catalog
    @Query private var cards: [OwnedCard]

    @State private var plan: Import.Plan?
    @State private var catalogMissing = false
    @State private var report: Import.Report?
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
                    ProgressView("Matching listings…")
                }
            }
            .navigationTitle("Import listings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(report == nil ? "Cancel" : "Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { run() }
                        .disabled(report != nil || !(plan?.hasWork ?? false))
                }
            }
        }
        .interactiveDismissDisabled(plan != nil && report == nil)
        .task { await build() }
    }

    // MARK: - Plan

    private func planList(_ plan: Import.Plan) -> some View {
        List {
            Section {
                LabeledContent("SKUs in the file", value: "\(plan.skuCount)")
                LabeledContent("In stock", value: "\(contents.rows.count) SKUs, \(contents.copyCount) copies")
                LabeledContent("Already tagged listed", value: "\(plan.alreadyListedCount)")
                LabeledContent("Held, to tag listed", value: "\(plan.toTagCount)")
                LabeledContent("New to inventory", value: "\(plan.toAddCount)")
                if !plan.skipped.isEmpty {
                    LabeledContent("Not imported", value: "\(plan.skipped.count)")
                }
                if !plan.unreadableRows.isEmpty {
                    LabeledContent("Rows not read", value: plan.unreadableRows.map(String.init).joined(separator: ", "))
                }
            } footer: {
                if catalogMissing {
                    Text("The catalog is not installed, so no row can match a card.")
                } else {
                    Text("A card you already hold takes the listed tag before the import adds a new card. The listed tag keeps List on TCGplayer from uploading the card again.")
                }
            }

            if plan.toAddCount > 0 {
                lineSection("New to inventory", lines: plan.lines.filter { $0.toAdd > 0 }, count: \.toAdd)
            }

            if plan.toTagCount > 0 {
                lineSection("Held, to tag listed", lines: plan.lines.filter { !$0.toTag.isEmpty }, count: \.toTag.count)
            }

            if !plan.skipped.isEmpty {
                Section {
                    ForEach(plan.skipped) { skipped in
                        rowLabel(skipped.row, detail: "\(skipped.row.line.condition) · \(skipped.reason.rawValue)")
                    }
                } header: {
                    Text("Not imported")
                } footer: {
                    Text("Search for each of these cards, add it, and tag it listed.")
                }
            }
        }
    }

    private func lineSection(_ title: String, lines: [Import.Line], count: KeyPath<Import.Line, Int>) -> some View {
        Section(title) {
            ForEach(lines) { line in
                rowLabel(line.row, detail: "\(line.row.line.condition) · ×\(line[keyPath: count])")
            }
        }
    }

    private func rowLabel(_ row: TCGplayerPricingCSV.Row, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.line.productName)
                .lineLimit(1)
            Text(row.line.setName)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func build() async {
        guard plan == nil else { return }
        var products: [Int: Int] = [:]
        if let database = catalog.database {
            let rows = contents.rows
            do {
                products = try await database.asyncRead { db in try TCGplayerPricingCSV.products(db, rows: rows) }
            } catch {
                failure = error.localizedDescription
                return
            }
        } else {
            catalogMissing = true
        }
        plan = Import.plan(contents, cards: cards, products: products)
    }

    private func run() {
        guard let plan else { return }
        do {
            report = try Import.apply(plan, context: modelContext)
        } catch {
            failure = error.localizedDescription
        }
    }
}
