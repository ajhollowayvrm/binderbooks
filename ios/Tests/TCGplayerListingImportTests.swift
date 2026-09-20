import Foundation
import GRDB
import SwiftData
import Testing
@testable import BinderBooks

/// The listings import. The fixture rows copy the shapes of his real pricing
/// export: quoted fields, SKUs with no stock, a Japanese condition, and a set
/// the catalog does not carry.
@Suite struct TCGplayerListingImportTests {
    static let header = "TCGplayer Id,Product Line,Set Name,Product Name,Title,Number,Rarity,Condition,TCG Market Price,TCG Direct Low,TCG Low Price With Shipping,TCG Low Price,Total Quantity,Add to Quantity,TCG Marketplace Price,Photo URL"

    static let export = header + "\r\n" + """
    "5001","Pokemon","SV03: Obsidian Flames","Charizard ex - 125/197","","125/197","Double Rare","Near Mint Holofoil","45.00","","46.0000","44.0000","2","0","44.0000",""\r
    "5003","Pokemon","SV03: Obsidian Flames","Charmander - 026/197","","026/197","Common","Near Mint Reverse Holofoil","0.40","","1.2000","0.2500","3","0","0.3000",""\r
    "5002","Pokemon","SV03: Obsidian Flames","Pidgeot ex - 164/197","","164/197","Ultra Rare","Near Mint Holofoil","8.00","","9.0000","7.5000","0","0","7.5000",""\r
    "7001","Pokemon Japan","M6: Storm Emeralda","Umbreon - 020/076","","020/076","Common","Near Mint - Japanese","1.20","","2.0000","1.0000","1","0","1.0000",""\r
    "9001","Pokemon","Not A Real Set","Missingno","","000/000","Common","Near Mint","","","","","1","0","1.0000",""\r
    "C-4505111","Pokemon","ME: Ascended Heroes","Ethan's Magcargo - 222/217","","222/217","Special Illustration Rare","Near Mint Holofoil","","","","","0","0","0.0000",""\r

    """

    // MARK: - Reading

    @Test func onlyTheStockIsRead() throws {
        let contents = try TCGplayerPricingCSV.read(Self.export)
        #expect(contents.skuCount == 6)
        #expect(contents.rows.map(\.skuId) == [5001, 5003, 7001, 9001])
        #expect(contents.copyCount == 7)
        #expect(contents.unreadableRows.isEmpty)

        let umbreon = try #require(contents.rows.first { $0.skuId == 7001 })
        #expect(umbreon.lineNumber == 5)
        #expect(umbreon.line.productLine == "Pokemon Japan")
        #expect(umbreon.line.setName == "M6: Storm Emeralda")
        #expect(umbreon.line.condition == "Near Mint - Japanese")
        #expect(umbreon.line.quantity == 1)
    }

    /// Two exports joined can repeat a SKU. The stock must not double.
    @Test func aRepeatedSkuCountsOnce() throws {
        let lines = Self.export.components(separatedBy: "\r\n")
        let joined = Self.export + lines[1] + "\r\n"
        let contents = try TCGplayerPricingCSV.read(joined)
        #expect(contents.skuCount == 6)
        #expect(contents.copyCount == 7)
    }

    /// A "C-" id with no stock is an ordinary row. With stock, the import
    /// cannot say what the id is, so it reports the row.
    @Test func aLetteredIdIsReportedOnlyWithStock() throws {
        #expect(try TCGplayerPricingCSV.read(Self.export).unreadableRows.isEmpty)

        let stocked = Self.export.replacingOccurrences(of: "\"0\",\"0\",\"0.0000\"", with: "\"1\",\"0\",\"0.0000\"")
        let contents = try TCGplayerPricingCSV.read(stocked)
        #expect(contents.unreadableRows == [7])
        #expect(contents.rows.map(\.skuId) == [5001, 5003, 7001, 9001])
    }

    @Test func aRowWithABadQuantityIsReportedNotDropped() throws {
        let text = Self.export.replacingOccurrences(of: "\"3\",\"0\",\"0.3000\"", with: "\"three\",\"0\",\"0.3000\"")
        let contents = try TCGplayerPricingCSV.read(text)
        #expect(contents.unreadableRows == [3])
        #expect(contents.rows.map(\.skuId) == [5001, 7001, 9001])
    }

    /// The stock check needs the SKUs TCGplayer listed once and has no stock
    /// for. A lettered id cannot match a SKU, so it is not kept.
    @Test func aSkuWithNoStockIsKeptForTheStockCheck() throws {
        let contents = try TCGplayerPricingCSV.read(Self.export)
        #expect(contents.emptyRows.map(\.skuId) == [5002])
        #expect(contents.emptyRows.first?.line.quantity == 0)
    }

    @Test func anOrdersFileIsRefused() {
        #expect(throws: TCGplayerPricingCSV.ReadError.missingColumns(["TCGplayer Id", "Set Name", "Total Quantity"])) {
            try TCGplayerPricingCSV.read(SalesOrderImportTests.mixedOrderList)
        }
    }

    @Test func theCatalogNamesEachSku() throws {
        let contents = try TCGplayerPricingCSV.read(Self.export)
        let products = try Fixture.make().read { db in try TCGplayerPricingCSV.products(db, rows: contents.rows) }
        #expect(products == [5001: 1, 5003: 3, 7001: 7])
    }

    // MARK: - Plan and apply

    @MainActor private func card(_ context: ModelContext, _ productId: Int, printing: String, condition: String = "Near Mint", acquired: String, tags: [String] = []) -> OwnedCard {
        let card = OwnedCard(productId: productId, printing: printing, condition: condition, confidence: .manual)
        card.acquiredAt = SalesOrderCSV.day(acquired)!
        card.tags = tags
        context.insert(card)
        return card
    }

    @Test @MainActor func heldCopiesAreTaggedBeforeNewCardsAreAdded() throws {
        let store = try CollectionStore.container(inMemory: true)
        let context = store.mainContext

        // Charizard ex ×2: one copy already listed, one held without the tag,
        // and a slab that a raw SKU must never take.
        let listedCharizard = card(context, 1, printing: "Holofoil", acquired: "2026-07-01", tags: ["listed"])
        let heldCharizard = card(context, 1, printing: "Holofoil", acquired: "2026-06-01")
        let slab = card(context, 1, printing: "Holofoil", acquired: "2026-05-01")
        slab.graderRaw = "psa"
        slab.gradeLabel = "10"

        // Charmander ×3: a sold copy, a Lightly Played copy, and a copy with no
        // printing. Only the last one fits.
        _ = card(context, 3, printing: "Reverse Holofoil", acquired: "2026-05-01", tags: ["sold"])
        let played = card(context, 3, printing: "Reverse Holofoil", condition: "Lightly Played", acquired: "2026-05-01")
        let noPrinting = card(context, 3, printing: "", acquired: "2026-06-01")
        try context.save()

        let contents = try TCGplayerPricingCSV.read(Self.export)
        let products = try Fixture.make().read { db in try TCGplayerPricingCSV.products(db, rows: contents.rows) }
        let plan = TCGplayerListingImport.plan(contents, cards: try context.fetch(FetchDescriptor<OwnedCard>()), products: products)

        #expect(plan.skuCount == 6)
        #expect(plan.skipped.map(\.row.skuId) == [9001])
        #expect(plan.skipped.first?.reason == .notInCatalog)

        let charizard = try #require(plan.lines.first { $0.row.skuId == 5001 })
        #expect(charizard.alreadyListed == [listedCharizard.id])
        #expect(charizard.toTag == [heldCharizard.id])
        #expect(charizard.toAdd == 0)

        let charmander = try #require(plan.lines.first { $0.row.skuId == 5003 })
        #expect(charmander.printing == "Reverse Holofoil")
        #expect(charmander.toTag == [noPrinting.id])
        #expect(charmander.toAdd == 2)

        let umbreon = try #require(plan.lines.first { $0.row.skuId == 7001 })
        #expect(umbreon.printing == "Normal")
        #expect(umbreon.toAdd == 1)

        #expect(plan.alreadyListedCount == 1)
        #expect(plan.toTagCount == 2)
        #expect(plan.toAddCount == 3)

        let report = try TCGplayerListingImport.apply(plan, costCents: 301, context: context)
        #expect(report.tagged == 2)
        #expect(report.added == 3)

        #expect(CardTagIndex.has(ReservedTag.listed, on: heldCharizard))
        #expect(heldCharizard.skuId == 5001)
        #expect(noPrinting.printing == "Reverse Holofoil")
        #expect(!CardTagIndex.has(ReservedTag.listed, on: slab))
        #expect(!CardTagIndex.has(ReservedTag.listed, on: played))

        let all = try context.fetch(FetchDescriptor<OwnedCard>())
        let added = all.filter { $0.skuId == 5003 && $0.id != noPrinting.id } + all.filter { $0.skuId == 7001 }
        #expect(added.count == 3)
        #expect(added.allSatisfy { CardTagIndex.has(ReservedTag.listed, on: $0) && $0.basisIsManual })
        #expect(added.map(\.acquisitionBasisCents).sorted() == [100, 100, 101])
        #expect(added.first { $0.skuId == 7001 }?.productId == 7)

        // The listing export must not offer the imported copies again.
        #expect(all.filter { CardTagIndex.has(ReservedTag.listed, on: $0) }.count == 6)

        // A second run of the same file changes nothing.
        let again = TCGplayerListingImport.plan(contents, cards: all, products: products)
        #expect(!again.hasWork)
        #expect(again.alreadyListedCount == 6)
    }

    // MARK: - Stock check

    /// His situation, 2026-09-15: open orders the app has not imported, and
    /// cards he listed by hand.
    @Test @MainActor func theStockCheckTagsHandListingsAndFlagsWhatMaySold() throws {
        let store = try CollectionStore.container(inMemory: true)
        let context = store.mainContext

        // Charizard ex: three copies tagged listed, and TCGplayer has two left.
        for day in ["2026-07-01", "2026-07-02", "2026-07-03"] {
            _ = card(context, 1, printing: "Holofoil", acquired: day, tags: ["listed"])
        }
        // Charmander: one tagged copy and three untagged, against a stock of
        // three. He listed two by hand.
        _ = card(context, 3, printing: "Reverse Holofoil", acquired: "2026-05-01", tags: ["listed"])
        let oldest = card(context, 3, printing: "Reverse Holofoil", acquired: "2026-05-02")
        let middle = card(context, 3, printing: "Reverse Holofoil", acquired: "2026-05-03")
        let newest = card(context, 3, printing: "Reverse Holofoil", acquired: "2026-05-04")
        // Pidgeot ex: TCGplayer listed it once and has none left.
        let pidgeot = card(context, 9, printing: "Holofoil", acquired: "2026-06-01")
        _ = card(context, 9, printing: "Holofoil", acquired: "2026-06-02", tags: ["sold"])
        // Base Set Charizard: TCGplayer never listed it.
        let fresh = card(context, 2, printing: "Holofoil", acquired: "2026-08-01")
        try context.save()

        let contents = try TCGplayerPricingCSV.read(Self.export)
        let products = try Fixture.make().read { db in
            try TCGplayerPricingCSV.products(db, rows: contents.rows + contents.emptyRows)
        }
        let result = TCGplayerStockCheck.check(contents, cards: try context.fetch(FetchDescriptor<OwnedCard>()), products: products)

        #expect(result.soldOnTCGplayer == 1)
        #expect(result.toTag == [oldest.id, middle.id])
        #expect(result.toCheck == [newest.id, pidgeot.id])
        #expect(!result.toTag.contains(fresh.id) && !result.toCheck.contains(fresh.id))
        // Missingno has stock and no product.
        #expect(result.unmatchedRows == 1)
    }

    @Test @MainActor func noCostLeavesTheBasisEmpty() throws {
        let store = try CollectionStore.container(inMemory: true)
        let contents = try TCGplayerPricingCSV.read(Self.export)
        let plan = TCGplayerListingImport.plan(contents, cards: [], products: [5001: 1])
        try TCGplayerListingImport.apply(plan, costCents: nil, context: store.mainContext)

        let cards = try store.mainContext.fetch(FetchDescriptor<OwnedCard>())
        #expect(cards.count == 2)
        #expect(cards.allSatisfy { $0.acquisitionBasisCents == 0 && !$0.basisIsManual })
        #expect(cards.allSatisfy { $0.condition == "Near Mint" && $0.printing == "Holofoil" && $0.isCommitted })
    }
}

/// His real pricing export against the real catalog and the seed books. Runs
/// only when both files are on the Mac. `build/` is never committed.
@Suite struct RealTCGplayerListingImportTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    static let export = root.appendingPathComponent("build/listings/pricing-export.csv")

    @Test @MainActor func everySkuWithStockFindsItsProduct() throws {
        try #require(FileManager.default.fileExists(atPath: Self.export.path), "no build/listings/pricing-export.csv")
        try #require(FileManager.default.fileExists(atPath: RealCatalogMatchTests.catalogPath), "no scripts/catalog.sqlite")

        let store = try CollectionStore.container(inMemory: true)
        let context = store.mainContext
        let seed = try CollectionExport.decode(try Data(contentsOf: SeedLedgerImportTests.file))
        try CollectionExport.apply(seed, to: context, mode: .replace)

        let contents = try TCGplayerPricingCSV.read(try String(contentsOf: Self.export, encoding: .utf8))
        var configuration = Configuration()
        configuration.readonly = true
        let catalog = try DatabaseQueue(path: RealCatalogMatchTests.catalogPath, configuration: configuration)
        let products = try catalog.read { db in try TCGplayerPricingCSV.products(db, rows: contents.rows) }
        let plan = TCGplayerListingImport.plan(contents, cards: try context.fetch(FetchDescriptor<OwnedCard>()), products: products)

        var lines = [
            "skus \(plan.skuCount), in stock \(contents.rows.count) (\(contents.copyCount) copies), unreadable \(plan.unreadableRows.count)",
            "already listed \(plan.alreadyListedCount), to tag \(plan.toTagCount), to add \(plan.toAddCount), skipped \(plan.skipped.count)",
        ]
        for skipped in plan.skipped {
            lines.append("skip \(skipped.reason.rawValue): \(skipped.row.line.setName) | \(skipped.row.line.productName) | \(skipped.row.line.number) | \(skipped.row.line.condition)")
        }
        for line in plan.lines {
            lines.append("sku \(line.row.skuId) product \(line.productId) \(line.condition) \(line.printing) listed \(line.alreadyListed.count) tag \(line.toTag.count) add \(line.toAdd): \(line.row.line.productName)")
        }
        try? lines.joined(separator: "\n").write(to: Self.root.appendingPathComponent("build/listings/plan-report.txt"), atomically: true, encoding: .utf8)

        #expect(plan.unreadableRows.isEmpty)
        #expect(plan.skipped.isEmpty)
        #expect(plan.alreadyListedCount + plan.toTagCount + plan.toAddCount == contents.copyCount)

        try TCGplayerListingImport.apply(plan, costCents: nil, context: context)
        let again = TCGplayerListingImport.plan(contents, cards: try context.fetch(FetchDescriptor<OwnedCard>()), products: products)
        #expect(!again.hasWork)
    }
}

/// His order list and pull sheet of 2026-09-15 against the real catalog. Runs
/// only when the files are on the Mac. `build/` is never committed, and the
/// order list holds buyer names.
@Suite struct RealTCGplayerOrderExportsTests {
    static let orderList = RealTCGplayerListingImportTests.root.appendingPathComponent("build/sales/order-list-2026-09-15.csv")
    static let pullSheet = RealTCGplayerListingImportTests.root.appendingPathComponent("build/sales/pull-sheet-2026-09-15.csv")

    @Test func hisExportsJoinAndNameTheirCards() throws {
        try #require(FileManager.default.fileExists(atPath: Self.pullSheet.path), "no build/sales/pull-sheet-2026-09-15.csv")
        let joined = try TCGplayerOrderExports.join(
            orderList: try String(contentsOf: Self.orderList, encoding: .utf8),
            pullSheet: try String(contentsOf: Self.pullSheet, encoding: .utf8)
        )
        let orders = joined.contents.orders
        #expect(orders.count == 149)
        // The pull sheet's own bad rows land here too now, labelled.
        #expect(joined.contents.unreadableRows.isEmpty)
        #expect(joined.unknownOrders.isEmpty)
        #expect(joined.ordersWithoutCards.count == 46)
        #expect(orders.reduce(0) { $0 + $1.cardCount } == 207)
        #expect(orders.filter { $0.status == "Ready to Ship" }.allSatisfy { !$0.lines.isEmpty })

        try #require(FileManager.default.fileExists(atPath: RealCatalogMatchTests.catalogPath), "no scripts/catalog.sqlite")
        var configuration = Configuration()
        configuration.readonly = true
        let catalog = try DatabaseQueue(path: RealCatalogMatchTests.catalogPath, configuration: configuration)
        let unnamed = try catalog.read { db in
            let categories = try SalesOrderCatalog.categoryIds(db)
            return try orders.flatMap(\.lines).filter { line in
                try SalesOrderCatalog.tcgplayerProduct(db, line: line, categories: categories) == nil
            }
        }
        // The catalog carries no Palworld cards.
        #expect(
            unnamed.allSatisfy { $0.productLine.hasPrefix("Palworld") },
            "not named: \(unnamed.map { "\($0.setName) | \($0.productName) | \($0.number)" })"
        )
    }
}
