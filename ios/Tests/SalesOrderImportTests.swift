import Foundation
import GRDB
import SwiftData
import Testing
@testable import BinderBooks

/// The sold-orders import. The fixture orders copy the shapes of his real file:
/// order money repeated on every line, a canceled order, a quantity of 2, and
/// eBay rows that carry a title and a grade instead of a set and a number.
@Suite struct SalesOrderImportTests {
    /// The five orders every plan and apply test works on, in the shapes he
    /// really exports: three TCGplayer orders across an order list and its pull
    /// sheet, and two eBay orders whose grade is in the listing title.
    ///
    /// Charmander's pull-sheet row comes first, so T-400's lines read
    /// Charmander then Charizard, and its "Quantity" of 1 is less than the
    /// orders it names add up to — his real pull sheet has rows like that.
    static let mixedOrderList = """
    Order #,Buyer Name,Order Date,Status,Shipping Type,Product Amt,Shipping Amt,Total Amt,Buyer Paid,Carrier Information
    T-100,Someone,2026-07-03,Completed - Paid,Standard,10.68,0.78,11.46,True,
    T-200,Someone,2026-07-05,Canceled,Standard,10.60,0.99,11.59,True,
    T-400,Someone,2026-09-08,Shipped - In Transit,Standard,5.87,0.78,6.65,True,

    """

    static let mixedPullSheet = """
    Product Line,Product Name,Condition,Number,Set,Rarity,Quantity,Main Photo URL,Set Release Date,SkuId,Order Quantity
    Pokemon,"Charmander, ""the"" one - 026/197",Near Mint Reverse Holofoil,026/197,SV03: Obsidian Flames,Common,1,,08/11/2023 00:00:00,5003,T-400:2
    Pokemon,Charizard ex - 125/197,Near Mint Holofoil,125/197,SV03: Obsidian Flames,Double Rare,1,,08/11/2023 00:00:00,5001,T-100:1 | T-400:1
    Pokemon,Pidgeot ex - 164/197,Near Mint Holofoil,164/197,SV03: Obsidian Flames,Ultra Rare,1,,08/11/2023 00:00:00,5002,T-200:1
    Orders Contained in Pull Sheet:,T-100|T-200|T-400

    """

    /// The grade rides in the title, the way eBay's report leaves it.
    static let mixedEbay = """
    ,,,,,,,,,
    "Sales Record Number","Order Number","Buyer Name","Item Number","Item Title","Quantity","Sold For","Shipping And Handling","Sale Date"
    "300","E-300","a-buyer","900","CGC Pristine 10 Umbreon 020/076 M6 Storm Emeralda Japanese","1","$43.00","","Sep-04-26"
    "500","E-500","a-buyer","901","CGC 10 Umbreon 020/076 Storm Emeralda JPN","1","$14.50","","Sep-10-26"

    2,record(s) downloaded,
    Seller ID : a-seller
    """

    /// The three files read together, as the picker hands them over.
    static func mixed() throws -> SalesOrderCSV.Contents {
        try SalesOrderSources.read([mixedOrderList, mixedPullSheet, mixedEbay]).contents
    }

    private func day(_ iso: String) -> Date { SalesOrderCSV.day(iso)! }

    // MARK: - Reading

    /// The three files land as one set of orders, with the money each export
    /// carries and the cards the pull sheet names.
    @Test func theThreeFilesReadIntoOneSetOfOrders() throws {
        let contents = try Self.mixed()
        #expect(contents.orders.map(\.orderId) == ["T-100", "T-200", "T-400", "E-300", "E-500"])
        #expect(contents.unreadableRows.isEmpty)

        let first = try #require(contents.orders.first)
        #expect(first.channel == .tcgplayer)
        #expect(first.productCents == 1_068)
        #expect(first.shippingChargedCents == 78)
        #expect(first.totalCents == 1_146)
        #expect(first.soldAt == day("2026-07-03"))
        #expect(!first.isCanceled)
        #expect(contents.orders[1].isCanceled)

        // The pull sheet's own quantity is 1; the order's count is what counts.
        let t400 = try #require(contents.orders.first { $0.orderId == "T-400" })
        #expect(t400.lines.count == 2)
        #expect(t400.cardCount == 3)
        #expect(t400.lines[0].productName == "Charmander, \"the\" one - 026/197")
        #expect(t400.lines[0].quantity == 2)
        #expect(t400.lines[0].skuId == 5003)

        let ebay = try #require(contents.orders.first { $0.orderId == "E-300" })
        #expect(ebay.channel == .ebay)
        #expect(ebay.productCents == 4_300)
        #expect(ebay.shippingChargedCents == 0)
        // No Condition column: the grade came out of the listing title.
        #expect(ebay.lines.first?.condition == "CGC Pristine 10")
    }

    // MARK: - Order list and pull sheet

    static let orderList = """
    Order #,Buyer Name,Order Date,Status,Shipping Type,Product Amt,Shipping Amt,Total Amt,Buyer Paid,Carrier Information
    62955D06-A,Someone,"Friday, 03 July 2026",Completed - Paid,Standard,10.68,0.78,11.46,True,
    62955D06-B,Someone,"Sunday, 05 July 2026",Canceled,Standard,10.60,0.99,11.59,True,
    62955D06-C,Someone,"Monday, 14 September 2026",Ready to Ship,Standard,5.87,1.49,7.36,True,
    62955D06-D,Someone,"Monday, 27 July 2026",Completed - Paid,Standard,2.00,0.78,2.78,True,

    """

    /// Charmander's "Quantity" says 1, and its orders add up to 3: his real
    /// pull sheet has rows like that.
    static let pullSheet = """
    Product Line,Product Name,Condition,Number,Set,Rarity,Quantity,Main Photo URL,Set Release Date,SkuId,Order Quantity
    Pokemon,Charizard ex - 125/197,Near Mint Holofoil,125/197,SV03: Obsidian Flames,Double Rare,1,,08/11/2023 00:00:00,5001,62955D06-A:1
    Pokemon,Charmander,Near Mint Reverse Holofoil,026/197,SV03: Obsidian Flames,Common,1,,08/11/2023 00:00:00,5003,62955D06-A:2 | 62955D06-C:1
    Pokemon,Pidgeot ex - 164/197,Near Mint Holofoil,164/197,SV03: Obsidian Flames,Ultra Rare,1,,08/11/2023 00:00:00,5002,62955D06-Z:1
    Orders Contained in Pull Sheet:,62955D06-A|62955D06-C|62955D06-Z

    """

    @Test func theTwoOrderExportsAreToldApart() {
        #expect(TCGplayerOrderExports.kind(of: Self.orderList) == .orderList)
        #expect(TCGplayerOrderExports.kind(of: Self.pullSheet) == .pullSheet)
        #expect(TCGplayerOrderExports.kind(of: "Name,Price\nCharizard,10.00\n") == nil)
    }

    @Test func theOrderListAndPullSheetJoinIntoOrders() throws {
        let joined = try TCGplayerOrderExports.join(orderList: Self.orderList, pullSheet: Self.pullSheet)
        let orders = joined.contents.orders
        #expect(orders.map(\.orderId) == ["62955D06-A", "62955D06-B", "62955D06-C", "62955D06-D"])
        #expect(joined.contents.unreadableRows.isEmpty)

        let a = orders[0]
        #expect(a.channel == .tcgplayer)
        #expect(a.soldAt == day("2026-07-03"))
        #expect(a.productCents == 1_068)
        #expect(a.shippingChargedCents == 78)
        #expect(a.lines.map(\.skuId) == [5001, 5003])
        #expect(a.lines.map(\.quantity) == [1, 2])
        #expect(a.lines[1].setName == "SV03: Obsidian Flames")
        #expect(a.lines[1].condition == "Near Mint Reverse Holofoil")

        #expect(orders[1].isCanceled && orders[1].lines.isEmpty)
        #expect(orders[2].status == "Ready to Ship")
        #expect(orders[2].lines.map(\.quantity) == [1])
        #expect(joined.ordersWithoutCards == ["62955D06-D"])
        #expect(joined.unknownOrders == ["62955D06-Z"])
    }

    @Test func aBadOrderQuantityIsReportedNotHalfRead() throws {
        let text = Self.pullSheet.replacingOccurrences(of: "62955D06-Z:1", with: "62955D06-Z")
        let joined = try TCGplayerOrderExports.join(orderList: Self.orderList, pullSheet: text)
        #expect(joined.contents.unreadableRows == [SalesOrderCSV.UnreadableRow(file: "Pull sheet", line: 4)])
        #expect(joined.unknownOrders.isEmpty)
    }

    /// His pull sheet of 2026-09-15 names two custom listings with their
    /// titles. Each number holds several cards there, so the name decides.
    @Test func aCustomListingTitleIsNotPartOfTheName() {
        #expect(TCGplayerOrderExports.productName("Team Rocket's Wobbuffet: Team Rocket's Wobbuffet #203 SV Promo Destined Rivals") == "Team Rocket's Wobbuffet")
        #expect(TCGplayerOrderExports.productName("Fezandipiti (Master Ball Pattern): Fezandipiti 045/131 Prismatic Evolutions Master Ball Holo") == "Fezandipiti (Master Ball Pattern)")
        #expect(TCGplayerOrderExports.productName("Dark Bell - 106/084") == "Dark Bell - 106/084")
        #expect(TCGplayerOrderExports.productName("Pokemon Card Game: Classic") == "Pokemon Card Game: Classic")
    }

    @Test func theFilesInTheWrongRolesAreRefused() {
        #expect(throws: TCGplayerOrderExports.JoinError.notTheTwoFiles) {
            try TCGplayerOrderExports.join(orderList: Self.pullSheet, pullSheet: Self.orderList)
        }
    }

    @Test func aFileWithoutTheEbayColumnsIsRefused() {
        #expect(throws: SalesOrderCSV.ReadError.missingColumns(EbayOrdersCSV.requiredColumns)) {
            try EbayOrdersCSV.read("Order Date,Status,Product Name\n2026-07-03,Paid,Charizard\n")
        }
    }

    @Test func aRowWithABadDateIsReportedNotDropped() throws {
        let text = Self.mixedOrderList.replacingOccurrences(of: "T-200,Someone,2026-07-05", with: "T-200,Someone,5 July")
        let joined = try TCGplayerOrderExports.join(orderList: text, pullSheet: Self.mixedPullSheet)
        #expect(joined.contents.unreadableRows == [SalesOrderCSV.UnreadableRow(file: "Order list", line: 3)])
        #expect(joined.contents.orders.count == 2)
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
        let contents = try Self.mixed()
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
            let line = SaleLine(sale: sale, card: card)
            line.describedAs = name
            context.insert(line)
        }
        return sale
    }

    @MainActor private func card(_ context: ModelContext, _ productId: Int, printing: String, condition: String = "Near Mint", acquired: String, tags: [String] = []) -> OwnedCard {
        let card = OwnedCard(productId: productId, printing: printing, condition: condition, confidence: .manual)
        card.acquiredAt = day(acquired)
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

        let oldest = card(context, 3, printing: "Reverse Holofoil", acquired: "2026-06-01")
        _ = card(context, 3, printing: "Reverse Holofoil", acquired: "2026-05-01", tags: ["sold"])
        let noCost = card(context, 3, printing: "Reverse Holofoil", acquired: "2026-07-01")
        _ = card(context, 3, printing: "Reverse Holofoil", condition: "Lightly Played", acquired: "2026-04-01")
        let newest = card(context, 3, printing: "Reverse Holofoil", acquired: "2026-08-01")
        let charizardSlab = card(context, 1, printing: "Holofoil", acquired: "2026-05-01")
        charizardSlab.graderRaw = "cgc"
        charizardSlab.gradeLabel = "10"
        let umbreonSlab = card(context, 7, printing: "Normal", acquired: "2026-08-01")
        umbreonSlab.graderRaw = "cgc"
        umbreonSlab.gradeLabel = "Pristine 10"
        let umbreonOut = card(context, 7, printing: "Normal", acquired: "2026-07-01", tags: ["at CGC"])
        try context.save()

        let contents = try Self.mixed()
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

    /// The one-way door, shut. He imports the order list on its own, so the
    /// sales land with no cards; the pull sheet arrives later and fills them
    /// in. Before this, the order number was already on the sale, so a later
    /// import called it settled and the cards were lost for good.
    @Test @MainActor func thePullSheetFillsInAnOrderImportedWithoutIt() throws {
        let store = try CollectionStore.container(inMemory: true)
        let context = store.mainContext
        history(context)
        let charmander = card(context, 3, printing: "Reverse Holofoil", acquired: "2026-06-01")
        let newer = card(context, 3, printing: "Reverse Holofoil", acquired: "2026-07-01")
        // Two Charizards: T-100 wants one and T-400 the other, oldest first.
        let charizard = card(context, 1, printing: "Holofoil", acquired: "2026-05-01")
        let charizardB = card(context, 1, printing: "Holofoil", acquired: "2026-08-01")
        try context.save()

        // The order list on its own.
        let listOnly = try SalesOrderSources.read([Self.mixedOrderList]).contents
        let catalog = try Fixture.make()
        let firstPlan = SalesOrderImport.plan(
            listOnly, sales: try context.fetch(FetchDescriptor<Sale>()),
            cards: try context.fetch(FetchDescriptor<OwnedCard>()),
            products: try catalog.read { db in try SalesOrderCatalog.resolve(db, orders: listOnly.orders) }
        )
        #expect(firstPlan.cardsToAdd.isEmpty)
        #expect(firstPlan.newSales.count == 2)
        #expect(firstPlan.newSales.allSatisfy { $0.lines.isEmpty })
        try SalesOrderImport.apply(firstPlan, removing: [], context: context)

        let t400 = try #require(try context.fetch(FetchDescriptor<Sale>()).first { $0.externalOrderId == "T-400" })
        #expect(t400.lines.isEmpty)
        #expect(!CardTagIndex.isSold(charmander))

        // The pull sheet, later. The sale is already numbered, so this is the
        // backfill and not a match or a new sale.
        let both = try SalesOrderSources.read([Self.mixedOrderList, Self.mixedPullSheet]).contents
        let products = try catalog.read { db in try SalesOrderCatalog.resolve(db, orders: both.orders) }
        let secondPlan = SalesOrderImport.plan(
            both, sales: try context.fetch(FetchDescriptor<Sale>()),
            cards: try context.fetch(FetchDescriptor<OwnedCard>()), products: products
        )
        #expect(secondPlan.newSales.isEmpty)
        #expect(secondPlan.matches.isEmpty)
        #expect(secondPlan.cardsToAdd.map(\.id) == ["T-100", "T-400"])

        // T-100 is the older order, so it takes the older Charizard.
        let onlyCharizard = try #require(secondPlan.cardsToAdd.first { $0.id == "T-100" })
        #expect(onlyCharizard.lines.map(\.cardId) == [charizard.id])

        let fill = try #require(secondPlan.cardsToAdd.first { $0.id == "T-400" })
        #expect(fill.lines.map(\.cardId) == [charmander.id, newer.id, charizardB.id])

        let report = try SalesOrderImport.apply(secondPlan, removing: [], context: context)
        #expect(report.created == 0)
        #expect(report.linesAdded == 4)
        #expect(report.cardsLinked == 4)
        #expect(t400.lines.count == 3)
        #expect(CardTagIndex.isSold(charmander))
        #expect(CardTagIndex.isSold(newer))
        #expect(CardTagIndex.isSold(charizard))
        #expect(CardTagIndex.isSold(charizardB))
        // The money he already had stays his.
        #expect(t400.grossCents == 587)
        #expect(t400.shippingChargedCents == 78)

        // And a third run has nothing left to do.
        let third = SalesOrderImport.plan(
            both, sales: try context.fetch(FetchDescriptor<Sale>()),
            cards: try context.fetch(FetchDescriptor<OwnedCard>()), products: products
        )
        #expect(third.cardsToAdd.isEmpty)
        #expect(third.alreadyOnBooks == 2)
    }

    /// A backfill and a new order draw from the same copies, so neither may
    /// take one the other already has.
    @Test @MainActor func aBackfillAndANewOrderNeverTakeTheSameCopy() throws {
        let store = try CollectionStore.container(inMemory: true)
        let context = store.mainContext
        history(context)
        // One Charizard, wanted by T-100 (already on the books, cardless) and
        // by T-400 (new).
        let only = card(context, 1, printing: "Holofoil", acquired: "2026-05-01")
        let onBooks = sale(context, "2026-07-03", gross: 1_146)
        onBooks.externalOrderId = "T-100"
        try context.save()

        let both = try SalesOrderSources.read([Self.mixedOrderList, Self.mixedPullSheet]).contents
        let plan = SalesOrderImport.plan(
            both, sales: try context.fetch(FetchDescriptor<Sale>()),
            cards: try context.fetch(FetchDescriptor<OwnedCard>()),
            products: try Fixture.make().read { db in try SalesOrderCatalog.resolve(db, orders: both.orders) }
        )
        let fill = try #require(plan.cardsToAdd.first { $0.id == "T-100" })
        let new = try #require(plan.newSales.first { $0.order.orderId == "T-400" })
        #expect(fill.lines.map(\.cardId) == [only.id])
        // T-400's Charizard line finds nothing left.
        #expect(new.lines.compactMap(\.cardId).isEmpty)
    }

    @Test @MainActor func aSwitchedOffRemovalStaysOnTheBooks() throws {
        let store = try CollectionStore.container(inMemory: true)
        let context = store.mainContext
        _ = sale(context, "2026-07-03", gross: 1_146, lines: [("Charizard ex", nil)])
        let duplicate = sale(context, "2026-07-02", gross: 1_146)
        try context.save()

        let contents = try Self.mixed()
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

/// His real orders against his real books. Runs only on the Mac, where
/// `build/sales/` holds his exports with the buyer names removed; `build/` is
/// never committed.
///
/// It read `sold-orders.csv` until 2026-09-20. That file is gone, so it reads
/// what the app now reads: the order list, its pull sheet, and eBay's report.
/// The counts this test used to pin — 302 products, 122 orders, 87 matches, 33
/// new — were measured against the old input and do not carry over. They are
/// not restated here rather than restated wrong; `build/sales/plan-report.txt`
/// is written on every run, so they can be pinned again from one real run.
@Suite struct RealSalesOrderImportTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    static let orderList = root.appendingPathComponent("build/sales/order-list-2026-09-15.csv")
    static let pullSheet = root.appendingPathComponent("build/sales/pull-sheet-2026-09-15.csv")
    static let ebayOrders = root.appendingPathComponent("build/sales/ebay-orders.csv")

    @Test @MainActor func hisOrdersLandOnTheSeedBooks() throws {
        try #require(FileManager.default.fileExists(atPath: Self.orderList.path), "no build/sales/order-list-*.csv")
        try #require(FileManager.default.fileExists(atPath: RealCatalogMatchTests.catalogPath), "no scripts/catalog.sqlite")

        let store = try CollectionStore.container(inMemory: true)
        let context = store.mainContext
        let seed = try CollectionExport.decode(try Data(contentsOf: SeedLedgerImportTests.file))
        try CollectionExport.apply(seed, to: context, mode: .replace)

        // Whatever of the three he has exported. The eBay report is optional.
        var texts = [try String(contentsOf: Self.orderList, encoding: .utf8)]
        for file in [Self.pullSheet, Self.ebayOrders] where FileManager.default.fileExists(atPath: file.path) {
            texts.append(try String(contentsOf: file, encoding: .utf8))
        }
        let contents = try SalesOrderSources.read(texts).contents
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
        for addition in plan.cardsToAdd {
            lines.append("cards for \(addition.order.channel.rawValue) \(addition.order.orderId) linked \(addition.linkedCount)/\(addition.lines.count)")
        }
        let seen = Set(plan.matches.map(\.order.orderId))
        for order in contents.orders where !seen.contains(order.orderId) && !plan.newSales.contains(where: { $0.order.orderId == order.orderId }) {
            lines.append("other \(order.channel.rawValue) \(order.orderId) \(order.status) \(order.totalCents)")
        }
        try? lines.joined(separator: "\n").write(to: Self.root.appendingPathComponent("build/sales/plan-report.txt"), atomically: true, encoding: .utf8)

        // Every file read clean, and every order landed in exactly one place.
        #expect(plan.unreadableRows.isEmpty)
        #expect(plan.orderCount == contents.orders.count)
        let placed = plan.alreadyOnBooks + plan.matches.count + plan.newSales.count
            + plan.cardsToAdd.count + plan.canceledNotOnBooks
            + plan.removals.filter { if case .canceled = $0.reason { true } else { false } }.count
        #expect(placed == plan.orderCount)

        try SalesOrderImport.apply(plan, removing: Set(plan.removals.map(\.saleId)), context: context)
        let again = SalesOrderImport.plan(
            contents, sales: try context.fetch(FetchDescriptor<Sale>()),
            cards: try context.fetch(FetchDescriptor<OwnedCard>()), products: products
        )
        // The whole point: a second run of the same files has nothing to do.
        #expect(again.newSales.isEmpty)
        #expect(again.matches.isEmpty)
        #expect(again.removals.isEmpty)
        #expect(again.cardsToAdd.isEmpty)
    }
}

/// eBay's All Orders Report, and picking the three exports in any combination.
/// The fixture copies the shapes of his real report of 2026-09-20: a first line
/// of bare commas, a padding row, a multi-item order written as a summary row
/// and its items, an order with no order number, a listing that is not a card,
/// and the two footer lines.
@Suite struct SalesOrderSourcesTests {
    static let ebay = """
    ,,,,,,,,,,,
    "Sales Record Number","Order Number","Buyer Name","Item Number","Item Title","Quantity","Sold For","Shipping And Handling","Total Price","Sale Date","Shipped On Date","Tracking Number"
    "","","","","","","","","","","",""
    "149","11-10000-00001","buyer_one","220000000001","2024 Pokemon Pikachu ex 122/106 Super Electric Breaker JP SR CGC Pristine 10","1","$90.00","$0.00","$97.99","Sep-18-26","","10000000000001"
    "145","","buyer_two","220000000002","Reshiram EX 95/99 Full Art Next Destinies Italian Pokemon Card 2012 NM Clean","1","$50.00","$0.00","$50.00","Sep-15-26","",""
    "142","11-10000-00002","buyer_three","220000000003","Apple AirPods 4 4th Gen MXP63LL/A No ANC White USB-C Case NEW FACTORY SEALED","1","$65.00","$0.00","$65.00","Sep-14-26","Sep-14-26","1Z000000000000001"
    "119","11-10000-00003","buyer_four","","","2","$28.00","$0.00","$29.55","Aug-25-26","Aug-26-26",""
    "119","11-10000-00003","buyer_four","220000000004","CGC GEM MINT 10 Numel Mega Dream ex 198/193 Japanese 2025 Holo AR Pokemon","1","$13.00","","","Aug-25-26","Aug-26-26","9400000000000000000001"
    "119","11-10000-00003","buyer_four","220000000005","CGC GEM MINT 10 Espeon ex Terastal Fest ex 063/187 Japanese Holo DR Pokemon","1","$15.00","","","Aug-25-26","Aug-26-26","9400000000000000000001"

    45,record(s) downloaded,
    Seller ID : a-seller
    """

    private func day(_ iso: String) -> Date { SalesOrderCSV.day(iso)! }

    // MARK: - Reading eBay

    @Test func theEbayReportReadsItsOrders() throws {
        let contents = try EbayOrdersCSV.read(Self.ebay)
        #expect(contents.orders.map(\.orderId) == ["11-10000-00001", "145", "11-10000-00002", "11-10000-00003"])
        #expect(contents.orders.allSatisfy { $0.channel == .ebay })
        // No Status column, so nothing in this file is ever canceled.
        #expect(contents.orders.allSatisfy { !$0.isCanceled })

        let first = try #require(contents.orders.first)
        #expect(first.soldAt == day("2026-09-18"))
        #expect(first.productCents == 9_000)
        #expect(first.shippingChargedCents == 0)
        #expect(first.lines.map(\.condition) == ["CGC Pristine 10"])
        #expect(first.lines.first?.quantity == 1)
    }

    /// The summary row is the order's money. Its items are the lines, and their
    /// prices are not added on top of it.
    @Test func aMultiItemOrderTakesItsMoneyFromTheSummaryRow() throws {
        let contents = try EbayOrdersCSV.read(Self.ebay)
        let order = try #require(contents.orders.first { $0.lines.count == 2 })
        #expect(order.orderId == "11-10000-00003")
        #expect(order.productCents == 2_800)
        #expect(order.cardCount == 2)
        #expect(order.lines.map(\.productName).allSatisfy { $0.hasPrefix("CGC GEM MINT 10") })
        #expect(order.lines.allSatisfy { $0.condition == "CGC GEM MINT 10" })
    }

    @Test func aBlankOrderNumberFallsBackToTheSalesRecord() throws {
        let contents = try EbayOrdersCSV.read(Self.ebay)
        let order = try #require(contents.orders.first { $0.orderId == "145" })
        #expect(order.productCents == 5_000)
        // Nothing in the title grades it, so it imports raw.
        #expect(order.lines.first?.condition == "")
    }

    /// The comma line, the padding row and the two footer lines are the
    /// report's furniture, not rows that would not read.
    @Test func theReportsOwnFurnitureIsNotAnUnreadableRow() throws {
        let contents = try EbayOrdersCSV.read(Self.ebay)
        #expect(contents.unreadableRows.isEmpty)
    }

    @Test func aRowWithABadDateIsReportedAgainstTheEbayFile() throws {
        let text = Self.ebay.replacingOccurrences(of: "\"Sep-18-26\"", with: "\"the 18th\"")
        let contents = try EbayOrdersCSV.read(text)
        #expect(contents.unreadableRows == [SalesOrderCSV.UnreadableRow(file: "eBay orders", line: 4)])
        #expect(contents.orders.count == 3)
    }

    @Test func ebaysDateFormatReads() {
        #expect(SalesOrderCSV.day("Sep-18-26") == SalesOrderCSV.day("2026-09-18"))
        #expect(SalesOrderCSV.day("Aug-25-26") == SalesOrderCSV.day("2026-08-25"))
    }

    /// The eBay import filed his orders in the year 26 from 2026-09-12 to
    /// 2026-09-22. The launch repair moves them to 2026, and a second run
    /// changes nothing.
    @Test @MainActor func aSaleFiledInTheYear26MovesTo2026() throws {
        let store = try CollectionStore.container(inMemory: true)
        let context = store.mainContext
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let wrong = Sale(soldAt: utc.date(from: DateComponents(year: 26, month: 9, day: 18, hour: 12))!, channelRaw: "ebay", grossCents: 1900)
        let right = Sale(soldAt: try #require(SalesOrderCSV.day("2026-09-19")), channelRaw: "ebay", grossCents: 500)
        context.insert(wrong)
        context.insert(right)
        try context.save()

        SalesOrderCSV.repairCenturyDates(context)
        #expect(wrong.soldAt == SalesOrderCSV.day("2026-09-18"))
        #expect(right.soldAt == SalesOrderCSV.day("2026-09-19"))

        SalesOrderCSV.repairCenturyDates(context)
        #expect(wrong.soldAt == SalesOrderCSV.day("2026-09-18"))
    }

    /// A title is full of numbers, so the grader word anchors the grade.
    @Test func theGradeComesOutOfTheListingTitle() {
        #expect(EbayOrdersCSV.grade(inTitle: "2024 Pokemon Pikachu ex 122/106 Super Electric Breaker JP SR CGC Pristine 10") == "CGC Pristine 10")
        #expect(EbayOrdersCSV.grade(inTitle: "CGC 10 Zamazenta 107/098 SV10 Glory of Team Rocket Art Rare Holo Japanese 2025") == "CGC 10")
        #expect(EbayOrdersCSV.grade(inTitle: "CGC GEM MINT 10 Eevee ex Terastal Fest ex 126/187 Japanese Holo DR Pokemon") == "CGC GEM MINT 10")
        #expect(EbayOrdersCSV.grade(inTitle: "CGC MINT 9 Gengar Nihil Zero 049/080 Japanese 2026 Non-Holo Pokemon") == "CGC MINT 9")
        #expect(EbayOrdersCSV.grade(inTitle: "2025 Pokemon SV Black Bolt Dwebble 129/086 Illustration Rare Holo PSA 9 MINT") == "PSA 9")
        // "Tag Team" is a card, not the grader TAG.
        #expect(EbayOrdersCSV.grade(inTitle: "2019 Pokemon Japanese Espeon & Deoxys GX 001/031 Tag Team Holo CGC Pristine 10") == "CGC Pristine 10")
        #expect(EbayOrdersCSV.grade(inTitle: "Reshiram EX 95/99 Full Art Next Destinies Italian Pokemon Card 2012 NM Clean") == "")
        #expect(EbayOrdersCSV.grade(inTitle: "Microsoft Xbox Series S 512GB White Console + Controller, HDMI & Power Cord") == "")
    }

    /// The grade the title gives is the grade the import matches copies on.
    @Test func theTitlesGradeReachesTheCondition() {
        let slab = SoldCondition.parse(EbayOrdersCSV.grade(inTitle: "CGC GEM MINT 10 Numel Mega Dream ex 198/193 Japanese"), channel: .ebay)
        #expect(slab.grader == "cgc")
        #expect(slab.grade == 10)
        #expect(slab.gradeHasWord)
        #expect(!slab.pristine)

        let raw = SoldCondition.parse(EbayOrdersCSV.grade(inTitle: "Reshiram EX 95/99 Full Art NM Clean"), channel: .ebay)
        #expect(raw == SoldCondition())
    }

    // MARK: - Picking the files

    @Test func eachFileIsToldApartByItsColumns() {
        #expect(SalesOrderSources.kind(of: SalesOrderSourcesTests.ebay) == .ebayOrders)
        #expect(SalesOrderSources.kind(of: SalesOrderImportTests.orderList) == .orderList)
        #expect(SalesOrderSources.kind(of: SalesOrderImportTests.pullSheet) == .pullSheet)
        #expect(SalesOrderSources.kind(of: "a,b,c\n1,2,3\n") == nil)
    }

    @Test func anyOneFileImportsOnItsOwn() throws {
        let ebay = try SalesOrderSources.read([Self.ebay])
        #expect(ebay.contents.orders.count == 4)

        // The order list alone: the orders and their money, no cards.
        let list = try SalesOrderSources.read([SalesOrderImportTests.orderList])
        #expect(list.contents.orders.count == 4)
        #expect(list.contents.orders.allSatisfy { $0.lines.isEmpty })
        #expect(list.ordersWithoutCards == ["62955D06-A", "62955D06-C", "62955D06-D"])
    }

    @Test func theOrderListAndPullSheetStillJoinThroughTheRouter() throws {
        let picked = try SalesOrderSources.read([SalesOrderImportTests.pullSheet, SalesOrderImportTests.orderList])
        #expect(picked.kinds == [.orderList, .pullSheet])
        #expect(picked.contents.orders.map(\.orderId) == ["62955D06-A", "62955D06-B", "62955D06-C", "62955D06-D"])
        #expect(picked.contents.orders[0].lines.map(\.quantity) == [1, 2])
        #expect(picked.ordersWithoutCards == ["62955D06-D"])
        #expect(picked.unknownOrders == ["62955D06-Z"])
    }

    @Test func allThreeFilesComeInTogether() throws {
        let picked = try SalesOrderSources.read([
            Self.ebay, SalesOrderImportTests.orderList, SalesOrderImportTests.pullSheet,
        ])
        #expect(picked.kinds == [.orderList, .pullSheet, .ebayOrders])
        #expect(picked.contents.orders.filter { $0.channel == .tcgplayer }.count == 4)
        #expect(picked.contents.orders.filter { $0.channel == .ebay }.count == 4)
        #expect(picked.contents.unreadableRows.isEmpty)
    }

    @Test func theOrderListAndTheEbayReportComeInTogether() throws {
        let picked = try SalesOrderSources.read([SalesOrderImportTests.orderList, Self.ebay])
        #expect(picked.kinds == [.orderList, .ebayOrders])
        #expect(picked.contents.orders.count == 8)
    }

    /// Every file that would not make sense on its own says what is missing.
    @Test func thePicksThatDoNotMakeSenseAreRefused() {
        #expect(throws: SalesOrderSources.PickError.pullSheetAlone) {
            try SalesOrderSources.read([SalesOrderImportTests.pullSheet])
        }
        #expect(throws: SalesOrderSources.PickError.nothingPicked) {
            try SalesOrderSources.read([])
        }
        #expect(throws: SalesOrderSources.PickError.unrecognized) {
            try SalesOrderSources.read(["Name,Price\nCharizard,10.00\n"])
        }
        #expect(throws: SalesOrderSources.PickError.pickedTwice("Order list")) {
            try SalesOrderSources.read([SalesOrderImportTests.orderList, SalesOrderImportTests.orderList])
        }
    }

    /// eBay's report reaches about three months back, so a year of selling is
    /// several of them. Overlapping months come through once.
    @Test func severalEbayReportsComeInTogether() throws {
        let picked = try SalesOrderSources.read([Self.ebay, Self.ebay])
        #expect(picked.kinds == [.ebayOrders, .ebayOrders])
        #expect(picked.contents.orders.count == 4)
    }

    /// A row that would not read says which file to look in, now that several
    /// come in at once.
    @Test func anUnreadableRowNamesItsFile() throws {
        let sheet = SalesOrderImportTests.pullSheet.replacingOccurrences(of: "62955D06-Z:1", with: "62955D06-Z")
        let ebay = Self.ebay.replacingOccurrences(of: "\"Sep-14-26\"", with: "\"the 14th\"")
        let picked = try SalesOrderSources.read([SalesOrderImportTests.orderList, sheet, ebay])
        #expect(picked.contents.unreadableRows.map(\.label) == ["Pull sheet line 4", "eBay orders line 6"])
    }
}
