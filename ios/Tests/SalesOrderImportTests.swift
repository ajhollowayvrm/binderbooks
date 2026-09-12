import Foundation
import GRDB
import SwiftData
import Testing
@testable import BinderBooks

/// The sold-orders import. The fixture orders copy the shapes of his real file:
/// order money repeated on every line, a canceled order, a quantity of 2, and
/// eBay rows that carry a title and a grade instead of a set and a number.
@Suite struct SalesOrderImportTests {
    static let tcgplayerOnly = """
    Order #,Order Date,Status,Buyer Name,Product Line,Set,Number,Product Name,Rarity,Condition,SkuId,Qty,Lines In Order,Cards In Order,Line Price Known,Product Amt,Shipping Amt,Total Amt,Shipping Type
    62955D06-A,"Friday, 03 July 2026",Completed - Paid,Someone,Pokemon,SV03: Obsidian Flames,125/197,Charizard ex - 125/197,Double Rare,Near Mint Holofoil,5001,1,2,3,False,10.68,0.78,11.46,Standard
    62955D06-A,"Friday, 03 July 2026",Completed - Paid,Someone,Pokemon,SV03: Obsidian Flames,026/197,"Charmander, ""the"" one - 026/197",Common,Near Mint Reverse Holofoil,5003,2,2,3,False,10.68,0.78,11.46,Standard
    62955D06-B,"Sunday, 05 July 2026",Canceled,Someone,Pokemon,SV03: Obsidian Flames,164/197,Pidgeot ex - 164/197,Ultra Rare,Near Mint Holofoil,5002,1,1,1,True,10.60,0.99,11.59,Standard

    """

    static let combined = """
    Marketplace,Order #,Order Date,Status,Buyer Name,Product Line,Set,Number,Product Name,Rarity,Condition,SkuId,eBay Item ID,Qty,Lines In Order,Cards In Order,Line Price Known,Product Amt,Shipping Amt,Total Amt,Shipping Type
    TCGplayer,T-100,2026-07-03,Completed - Paid,A Buyer,Pokemon,SV03: Obsidian Flames,125/197,Charizard ex - 125/197,Double Rare,Near Mint Holofoil,5001,,1,1,1,True,10.68,0.78,11.46,Standard
    TCGplayer,T-200,2026-07-05,Canceled,A Buyer,Pokemon,SV03: Obsidian Flames,164/197,Pidgeot ex - 164/197,Ultra Rare,Near Mint Holofoil,5002,,1,1,1,True,10.60,0.99,11.59,Standard
    eBay,E-300,2026-09-04,Delivered,buyer1,Pokemon,,,Umbreon 020/076 M6 Storm Emeralda Japanese,,CGC Pristine 10,,999,1,1,1,True,43.0,,,
    TCGplayer,T-400,2026-09-08,Shipped - In Transit,A Buyer,Pokemon,SV03: Obsidian Flames,026/197,Charmander - 026/197,Common,Near Mint Reverse Holofoil,5003,,2,2,3,False,5.87,0.78,6.65,Standard
    TCGplayer,T-400,2026-09-08,Shipped - In Transit,A Buyer,Pokemon,SV03: Obsidian Flames,125/197,Charizard ex - 125/197,Double Rare,Near Mint Holofoil,5001,,1,2,3,False,5.87,0.78,6.65,Standard
    eBay,E-500,2026-09-10,Shipped,buyer2,Pokemon,,,Umbreon 020/076 Storm Emeralda JPN,,CGC 10,,998,1,1,1,True,14.5,,,
    """

    private func day(_ iso: String) -> Date { SalesOrderCSV.day(iso)! }

    // MARK: - Reading

    @Test func theMoneyIsReadOncePerOrder() throws {
        let contents = try SalesOrderCSV.read(Self.tcgplayerOnly)
        #expect(contents.orders.count == 2)
        #expect(contents.unreadableRows.isEmpty)

        let first = try #require(contents.orders.first)
        #expect(first.channel == .tcgplayer)
        #expect(first.productCents == 1_068)
        #expect(first.shippingChargedCents == 78)
        #expect(first.totalCents == 1_146)
        #expect(first.lines.count == 2)
        #expect(first.cardCount == 3)
        #expect(first.soldAt == day("2026-07-03"))
        #expect(first.lines[1].productName == "Charmander, \"the\" one - 026/197")
        #expect(first.lines[1].skuId == 5003)
        #expect(!first.isCanceled)
        #expect(contents.orders[1].isCanceled)
    }

    @Test func theCombinedFileReadsBothChannels() throws {
        let contents = try SalesOrderCSV.read(Self.combined)
        #expect(contents.orders.map(\.orderId) == ["T-100", "T-200", "E-300", "T-400", "E-500"])
        let ebay = try #require(contents.orders.first { $0.orderId == "E-300" })
        #expect(ebay.channel == .ebay)
        #expect(ebay.productCents == 4_300)
        #expect(ebay.shippingChargedCents == 0)
        #expect(ebay.lines.first?.condition == "CGC Pristine 10")
    }

    @Test func aFileWithoutTheOrderColumnsIsRefused() {
        #expect(throws: SalesOrderCSV.ReadError.missingColumns(["Order #", "Product Amt"])) {
            try SalesOrderCSV.read("Order Date,Status,Product Name\n2026-07-03,Paid,Charizard\n")
        }
    }

    @Test func aRowWithABadDateIsReportedNotDropped() throws {
        let text = Self.combined.replacingOccurrences(of: "T-200,2026-07-05", with: "T-200,5 July")
        let contents = try SalesOrderCSV.read(text)
        #expect(contents.unreadableRows == [3])
        #expect(contents.orders.count == 4)
    }

    @Test func conditionsParse() {
        let raw = SoldCondition.parse("Near Mint Reverse Holofoil - Japanese", channel: .tcgplayer)
        #expect(raw.condition == "Near Mint")
        #expect(raw.printing == "Reverse Holofoil")
        #expect(raw.grader == nil)

        #expect(SoldCondition.parse("Lightly Played", channel: .tcgplayer).printing == "Normal")

        let slab = SoldCondition.parse("CGC 10 Pristine", channel: .ebay)
        #expect(slab.grader == "cgc")
        #expect(slab.grade == 10)
        #expect(slab.pristine)
        #expect(slab.gradeHasWord)

        let bare = SoldCondition.parse("CGC 10", channel: .ebay)
        #expect(bare.grade == 10)
        #expect(!bare.gradeHasWord)

        #expect(SoldCondition.parse("NM (ungraded)", channel: .ebay) == SoldCondition())
    }

    // MARK: - Catalog

    @Test func theCatalogNamesEachCopy() throws {
        let contents = try SalesOrderCSV.read(Self.combined)
        let queue = try Fixture.make()
        let products = try queue.read { db in try SalesOrderCatalog.resolve(db, orders: contents.orders) }
        typealias Key = SalesOrderCatalog.CopyKey

        #expect(products[Key(orderId: "T-100", line: 0, copy: 0)] == 1)
        #expect(products[Key(orderId: "T-400", line: 0, copy: 0)] == 3)
        #expect(products[Key(orderId: "T-400", line: 0, copy: 1)] == 3)
        #expect(products[Key(orderId: "T-400", line: 1, copy: 0)] == 1)
        // Tandemaus holds 020/076 in English. The title says Japanese.
        #expect(products[Key(orderId: "E-300", line: 0, copy: 0)] == 7)
        #expect(products[Key(orderId: "E-500", line: 0, copy: 0)] == 7)
    }

    @Test func aPatternPrintingIsDecidedByName() throws {
        let queue = try Fixture.make()
        let line = SalesOrderCSV.Line(
            productLine: "Pokemon", setName: "SV: Black Bolt", number: "001/086",
            productName: "Snivy (Poke Ball Pattern)", condition: "Near Mint", skuId: nil, quantity: 1
        )
        let productId = try queue.read { db in
            try SalesOrderCatalog.tcgplayerProduct(db, line: line, categories: ["pokemon": 3])
        }
        #expect(productId == 14)
    }

    /// TCGplayer puts the variant after the number. The plain card at the same
    /// number must not take the sale, and a variant must not hide the plain card.
    @Test func aVariantAfterTheNumberIsNotThePlainCard() throws {
        let queue = try Fixture.make()
        func product(_ name: String) throws -> Int? {
            let line = SalesOrderCSV.Line(
                productLine: "Pokemon", setName: "SV: Black Bolt", number: "001/086",
                productName: name, condition: "Near Mint", skuId: nil, quantity: 1
            )
            return try queue.read { db in try SalesOrderCatalog.tcgplayerProduct(db, line: line, categories: ["pokemon": 3]) }
        }
        #expect(try product("Snivy - 001/086 (Master Ball Pattern)") == 15)
        #expect(try product("Snivy - 001/086") == 13)
    }

    @Test func anEnglishTitleFindsTheEnglishCard() throws {
        let queue = try Fixture.make()
        let productId = try queue.read { db in
            try SalesOrderCatalog.ebayProduct(db, title: "Tandemaus 020/076 Prismatic Evolutions", number: CollectorNumber.parse("020/076"))
        }
        #expect(productId == 16)
    }

    // MARK: - Fees

    @Test @MainActor func theFitRecoversAFixedFeeAndARate() throws {
        let store = try CollectionStore.container(inMemory: true)
        let context = store.mainContext
        history(context)
        let estimate = FeeEstimate.derived(from: try context.fetch(FetchDescriptor<Sale>()))
        let fit = try #require(estimate.fit(for: "tcgplayer"))
        #expect(fit.orderCount == 5)
        #expect(fit.feeCents(onCents: 400) == 83)
        #expect(fit.feeCents(onCents: 1_146) == 182)
        #expect(fit.postageCents == 78)
        #expect(estimate.fit(for: "ebay") == estimate.overall)
    }

    @Test func tooFewOrdersFitNothing() {
        #expect(FeeEstimate.fit([(100, 30), (200, 40)], postage: []) == nil)
    }

    @Test @MainActor func anEstimatedOrderIsLeftOutOfTheRates() throws {
        let store = try CollectionStore.container(inMemory: true)
        let context = store.mainContext
        let real = Sale(soldAt: day("2026-06-01"), channelRaw: "tcgplayer", grossCents: 1_000)
        real.marketplaceFeesCents = 150
        let estimated = Sale(soldAt: day("2026-06-02"), channelRaw: "tcgplayer", grossCents: 9_000)
        estimated.marketplaceFeesCents = 9_000
        estimated.costsEstimated = true
        context.insert(real)
        context.insert(estimated)
        try context.save()

        let rates = ChannelRates.derived(from: try context.fetch(FetchDescriptor<Sale>()))
        #expect(rates.orderCount == 1)
        #expect(rates.blendedFeeBasisPoints == 1_500)
    }

    // MARK: - Plan and apply

    /// Five orders with real fees: 30 cents plus 13.25%.
    @MainActor private func history(_ context: ModelContext) {
        for (index, total) in [400, 800, 1_200, 2_000, 4_000].enumerated() {
            let sale = Sale(soldAt: day("2026-06-0\(index + 1)"), channelRaw: "tcgplayer", grossCents: total)
            sale.marketplaceFeesCents = 30 + total * 1_325 / 10_000
            sale.shippingCostCents = index < 2 ? 78 : (index == 2 ? 597 : 0)
            sale.externalOrderId = "H-\(index)"
            context.insert(sale)
        }
    }

    @MainActor private func sale(_ context: ModelContext, _ iso: String, gross: Int, channel: String = "tcgplayer", lines: [(String, OwnedCard?)] = []) -> Sale {
        let sale = Sale(soldAt: day(iso), channelRaw: channel, grossCents: gross)
        context.insert(sale)
        for (name, card) in lines {
            let line = SaleLine(sale: sale, card: card, basisCents: 0, basisIncomplete: true)
            line.describedAs = name
            context.insert(line)
        }
        return sale
    }

    @MainActor private func card(_ context: ModelContext, _ productId: Int, printing: String, condition: String = "Near Mint", acquired: String, basis: Int = 0, tags: [String] = []) -> OwnedCard {
        let card = OwnedCard(productId: productId, printing: printing, condition: condition, confidence: .manual)
        card.acquiredAt = day(acquired)
        card.acquisitionBasisCents = basis
        card.tags = tags
        context.insert(card)
        return card
    }

    @Test @MainActor func ordersMatchCreateAndRemove() throws {
        let store = try CollectionStore.container(inMemory: true)
        let context = store.mainContext
        history(context)

        let pidgeot = card(context, 9, printing: "Holofoil", acquired: "2026-06-01", tags: ["sold"])
        pidgeot.status = .sold
        let s1 = sale(context, "2026-07-03", gross: 1_146, lines: [("Charizard ex", nil)])
        let s2 = sale(context, "2026-07-02", gross: 1_146)
        let s3 = sale(context, "2026-07-05", gross: 1_159, lines: [("Pidgeot ex", pidgeot)])
        let s4 = sale(context, "2026-09-05", gross: 4_300, lines: [("Umbreon", nil)])

        let oldest = card(context, 3, printing: "Reverse Holofoil", acquired: "2026-06-01", basis: 40)
        _ = card(context, 3, printing: "Reverse Holofoil", acquired: "2026-05-01", basis: 25, tags: ["sold"])
        let noCost = card(context, 3, printing: "Reverse Holofoil", acquired: "2026-07-01")
        _ = card(context, 3, printing: "Reverse Holofoil", condition: "Lightly Played", acquired: "2026-04-01")
        let newest = card(context, 3, printing: "Reverse Holofoil", acquired: "2026-08-01")
        let charizardSlab = card(context, 1, printing: "Holofoil", acquired: "2026-05-01")
        charizardSlab.graderRaw = "cgc"
        charizardSlab.gradeLabel = "10"
        let umbreonSlab = card(context, 7, printing: "Normal", acquired: "2026-08-01", basis: 900)
        umbreonSlab.graderRaw = "cgc"
        umbreonSlab.gradeLabel = "Pristine 10"
        let umbreonOut = card(context, 7, printing: "Normal", acquired: "2026-07-01", tags: ["at CGC"])
        try context.save()

        let contents = try SalesOrderCSV.read(Self.combined)
        let products = try Fixture.make().read { db in try SalesOrderCatalog.resolve(db, orders: contents.orders) }
        let sales = try context.fetch(FetchDescriptor<Sale>())
        let cards = try context.fetch(FetchDescriptor<OwnedCard>())
        let plan = SalesOrderImport.plan(contents, sales: sales, cards: cards, products: products)

        #expect(plan.orderCount == 5)
        #expect(plan.alreadyOnBooks == 0)
        #expect(plan.canceledNotOnBooks == 0)

        // The sale that names the card wins over the one with only a price.
        let charizard = try #require(plan.matches.first { $0.order.orderId == "T-100" })
        #expect(charizard.saleId == s1.id)
        #expect(charizard.channelBefore == nil)
        let umbreon = try #require(plan.matches.first { $0.order.orderId == "E-300" })
        #expect(umbreon.saleId == s4.id)
        #expect(umbreon.channelBefore == "tcgplayer")

        #expect(Set(plan.removals.map(\.saleId)) == [s2.id, s3.id])
        #expect(plan.removals.first { $0.saleId == s2.id }?.reason == .duplicate(orderId: "T-100"))
        #expect(plan.removals.first { $0.saleId == s3.id }?.reason == .canceled(orderId: "T-200"))

        let t400 = try #require(plan.newSales.first { $0.order.orderId == "T-400" })
        #expect(t400.lines.map(\.cardId) == [oldest.id, noCost.id, nil])
        #expect(t400.lines.map(\.basisCents) == [40, nil, nil])
        #expect(t400.feeCents == 118)
        #expect(t400.postageCents == 78)
        // A slab takes the eBay sale over an older copy still marked at CGC.
        let e500 = try #require(plan.newSales.first { $0.order.orderId == "E-500" })
        #expect(e500.lines.map(\.cardId) == [umbreonSlab.id])

        let report = try SalesOrderImport.apply(plan, removing: [s2.id, s3.id], context: context)
        #expect(report.numbered == 2)
        #expect(report.channelsCorrected == 1)
        #expect(report.created == 2)
        #expect(report.cardsLinked == 3)
        #expect(report.removed == 2)
        #expect(report.cardsReturned == 1)

        #expect(s1.externalOrderId == "T-100")
        #expect(s4.externalOrderId == "E-300")
        #expect(s4.channelRaw == "ebay")
        #expect(CardTagIndex.isSold(oldest))
        #expect(CardTagIndex.isSold(noCost))
        #expect(CardTagIndex.isSold(umbreonSlab))
        #expect(!CardTagIndex.isSold(newest))
        #expect(!CardTagIndex.isSold(umbreonOut))
        #expect(!CardTagIndex.isSold(pidgeot))
        #expect(oldest.skuId == 5003)

        let after = try context.fetch(FetchDescriptor<Sale>())
        let created = try #require(after.first { $0.externalOrderId == "T-400" })
        #expect(created.costsEstimated)
        #expect(created.grossCents == 587)
        #expect(created.shippingChargedCents == 78)
        #expect(created.marketplaceFeesCents == 118)
        #expect(created.lines.count == 3)
        #expect(created.realizedGainCents == nil)
        #expect(!after.contains { $0.id == s2.id || $0.id == s3.id })

        // A second run of the same file changes nothing.
        let again = SalesOrderImport.plan(
            contents, sales: after, cards: try context.fetch(FetchDescriptor<OwnedCard>()), products: products
        )
        #expect(again.alreadyOnBooks == 4)
        #expect(again.matches.isEmpty)
        #expect(again.newSales.isEmpty)
        #expect(again.removals.isEmpty)
        #expect(again.canceledNotOnBooks == 1)
    }

    @Test @MainActor func aSwitchedOffRemovalStaysOnTheBooks() throws {
        let store = try CollectionStore.container(inMemory: true)
        let context = store.mainContext
        _ = sale(context, "2026-07-03", gross: 1_146, lines: [("Charizard ex", nil)])
        let duplicate = sale(context, "2026-07-02", gross: 1_146)
        try context.save()

        let contents = try SalesOrderCSV.read(Self.combined)
        let plan = SalesOrderImport.plan(contents, sales: try context.fetch(FetchDescriptor<Sale>()), cards: [], products: [:])
        #expect(plan.removals.map(\.saleId) == [duplicate.id])
        try SalesOrderImport.apply(plan, removing: [], context: context)
        #expect(try context.fetch(FetchDescriptor<Sale>()).contains { $0.id == duplicate.id })
    }

    @Test @MainActor func theEstimateFlagSurvivesExport() throws {
        let store = try CollectionStore.container(inMemory: true)
        let sale = Sale(soldAt: day("2026-09-08"), channelRaw: "tcgplayer", grossCents: 587)
        sale.costsEstimated = true
        store.mainContext.insert(sale)
        try store.mainContext.save()

        let file = try CollectionExport.decode(try CollectionExport.exportData(store.mainContext))
        let copy = try CollectionStore.container(inMemory: true)
        try CollectionExport.apply(file, to: copy.mainContext, mode: .replace)
        #expect(try copy.mainContext.fetch(FetchDescriptor<Sale>()).first?.costsEstimated == true)
    }
}

/// His real orders against his real books. Runs only when both files are on
/// the Mac: `build/sales/sold-orders.csv` is his export with the buyer names
/// removed, and `build/` is never committed.
@Suite struct RealSalesOrderImportTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    static let orders = root.appendingPathComponent("build/sales/sold-orders.csv")

    @Test @MainActor func hisOrdersLandOnTheSeedBooks() throws {
        try #require(FileManager.default.fileExists(atPath: Self.orders.path), "no build/sales/sold-orders.csv")
        try #require(FileManager.default.fileExists(atPath: RealCatalogMatchTests.catalogPath), "no scripts/catalog.sqlite")

        let store = try CollectionStore.container(inMemory: true)
        let context = store.mainContext
        let seed = try CollectionExport.decode(try Data(contentsOf: SeedLedgerImportTests.file))
        try CollectionExport.apply(seed, to: context, mode: .replace)

        let contents = try SalesOrderCSV.read(try String(contentsOf: Self.orders, encoding: .utf8))
        var configuration = Configuration()
        configuration.readonly = true
        let catalog = try DatabaseQueue(path: RealCatalogMatchTests.catalogPath, configuration: configuration)
        let products = try catalog.read { db in try SalesOrderCatalog.resolve(db, orders: contents.orders) }

        let plan = SalesOrderImport.plan(
            contents, sales: try context.fetch(FetchDescriptor<Sale>()),
            cards: try context.fetch(FetchDescriptor<OwnedCard>()), products: products
        )

        var lines = [
            "orders \(plan.orderCount), on books \(plan.alreadyOnBooks), matched \(plan.matches.count), new \(plan.newSales.count), canceled not on books \(plan.canceledNotOnBooks), unreadable \(plan.unreadableRows.count), unidentified \(plan.unidentifiedCards)",
            "copies named by the catalog \(products.count) of \(contents.orders.reduce(0) { $0 + $1.cardCount })",
        ]
        for match in plan.channelCorrections {
            lines.append("channel \(match.channelBefore ?? "") -> \(match.order.channel.rawValue): \(match.order.orderId) \(match.order.lines.first?.productName ?? "")")
        }
        for removal in plan.removals {
            lines.append("remove \(removal.reason) \(removal.soldAt) \(removal.grossCents) \(removal.describedAs)")
        }
        for new in plan.newSales {
            lines.append("new \(new.order.channel.rawValue) \(new.order.orderId) \(new.order.soldAt) total \(new.order.totalCents) fee \(new.feeCents) post \(new.postageCents) linked \(new.linkedCount)/\(new.lines.count)")
        }
        let seen = Set(plan.matches.map(\.order.orderId))
        for order in contents.orders where !seen.contains(order.orderId) && !plan.newSales.contains(where: { $0.order.orderId == order.orderId }) {
            lines.append("other \(order.channel.rawValue) \(order.orderId) \(order.status) \(order.totalCents)")
        }
        try? lines.joined(separator: "\n").write(to: Self.root.appendingPathComponent("build/sales/plan-report.txt"), atomically: true, encoding: .utf8)

        #expect(products.count == 302)
        #expect(plan.unidentifiedCards == 0)
        #expect(plan.orderCount == 122)
        #expect(plan.unreadableRows.isEmpty)
        #expect(plan.matches.count == 87)
        #expect(plan.newSales.count == 33)
        #expect(plan.newSales.filter { $0.order.channel == .ebay }.reduce(0) { $0 + $1.order.productCents } == 22_700)
        #expect(plan.newSales.filter { $0.order.channel == .tcgplayer }.reduce(0) { $0 + $1.order.totalCents } == 12_484)
        #expect(Set(plan.channelCorrections.map { $0.order.channel }) == [.ebay])
        #expect(plan.channelCorrections.count == 2)
        #expect(plan.removals.filter { if case .canceled = $0.reason { true } else { false } }.count == 1)
        #expect(plan.removals.filter { if case .duplicate = $0.reason { true } else { false } }.count == 2)

        try SalesOrderImport.apply(plan, removing: Set(plan.removals.map(\.saleId)), context: context)
        let again = SalesOrderImport.plan(
            contents, sales: try context.fetch(FetchDescriptor<Sale>()),
            cards: try context.fetch(FetchDescriptor<OwnedCard>()), products: products
        )
        #expect(again.newSales.isEmpty)
        #expect(again.matches.isEmpty)
        #expect(again.removals.isEmpty)
    }
}
