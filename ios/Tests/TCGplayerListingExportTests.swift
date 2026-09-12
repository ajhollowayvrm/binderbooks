import Foundation
import Testing
@testable import BinderBooks

@Suite struct TCGplayerListingExportTests {
    private typealias Export = TCGplayerListingExport

    /// Captured from TCGplayer on 2026-09-11, trimmed: Crobat VMAX SWSH099,
    /// Near Mint Holofoil English, cheapest by price plus shipping. The ids
    /// arrive as doubles.
    let listing = """
    {"errors":[],"results":[{"totalResults":134,"resultId":"li1","aggregations":{},"results":[{"directProduct":true,"listingId":868547582.0,"channelId":0.0,"conditionId":85.0,"rankedShippingPrice":1.49,"productId":232613.0,"printing":"Holofoil","sellerShippingPrice":0.0,"language":"English","shippingPrice":1.49,"condition":"Near Mint","productConditionId":4780851.0,"listingType":"standard","quantity":1.0,"sellerPrice":2.04,"price":2.04}]}]}
    """

    /// The same product asked for a printing it does not have.
    let noListing = """
    {"errors":[],"results":[{"totalResults":0,"resultId":"li2","aggregations":{"condition":[],"quantity":[],"listingType":[],"language":[],"printing":[]},"results":[]}]}
    """

    let details = """
    {"productId":232613.0,"productName":"Crobat VMAX - SWSH099","foilOnly":true,"skus":[{"sku":4780851,"condition":"Near Mint","variant":"Holofoil","language":"English"},{"sku":4780852,"condition":"Lightly Played","variant":"Holofoil","language":"English"}]}
    """

    // MARK: - Client parsing

    @Test func theCheapestListingCarriesItsSku() throws {
        let low = try #require(try TCGplayerMarketClient.parseCheapest(Data(listing.utf8)))
        #expect(low == .init(skuId: 4_780_851, priceCents: 204, shippingCents: 149))
        #expect(low.totalCents == 353)
    }

    @Test func aSkuNobodySellsIsNil() throws {
        #expect(try TCGplayerMarketClient.parseCheapest(Data(noListing.utf8)) == nil)
    }

    @Test func anotherShapeIsUnreadable() {
        #expect(throws: TCGplayerMarketClient.Failure.unreadable) {
            try TCGplayerMarketClient.parseCheapest(Data("{}".utf8))
        }
        #expect(throws: TCGplayerMarketClient.Failure.unreadable) {
            try TCGplayerMarketClient.parseSkus(Data("{\"productId\": 1}".utf8))
        }
    }

    @Test func theSkuListReads() throws {
        let skus = try TCGplayerMarketClient.parseSkus(Data(details.utf8))
        #expect(skus.count == 2)
        #expect(skus.first == .init(skuId: 4_780_851, condition: "Near Mint", printing: "Holofoil", language: "English"))
    }

    @Test func theRequestAsksForOneSkuCheapestFirst() throws {
        let data = try TCGplayerMarketClient.listingsBody(condition: "Lightly Played", printing: "Reverse Holofoil", language: "Japanese")
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let term = try #require((body["filters"] as? [String: Any])?["term"] as? [String: Any])
        #expect(term["condition"] as? [String] == ["Lightly Played"])
        #expect(term["printing"] as? [String] == ["Reverse Holofoil"])
        #expect(term["language"] as? [String] == ["Japanese"])
        #expect(term["listingType"] as? [String] == ["standard"])
        #expect(body["size"] as? Int == 1)
        #expect((body["sort"] as? [String: String])?["field"] == "price+shipping")
    }

    @Test func dollarsRoundToTheNearestCent() throws {
        #expect(TCGplayerMarketClient.cents(try #require(Decimal(string: "2.04"))) == 204)
        #expect(TCGplayerMarketClient.cents(try #require(Decimal(string: "2.0399999"))) == 204)
        #expect(TCGplayerMarketClient.cents(try #require(Decimal(string: "2.035"))) == 204)
    }

    // MARK: - Which cards

    @Test @MainActor func theCardsHeKeepsOrCannotSellStayOut() {
        #expect(Export.skipReason(for: card(1), hit: hit(1)) == nil)

        let slab = card(1)
        slab.graderRaw = "psa"
        slab.gradeLabel = "10"
        #expect(Export.skipReason(for: slab, hit: hit(1)) == .slab)

        let box = card(1)
        box.isSealedSelf = true
        #expect(Export.skipReason(for: box, hit: hit(1)) == .sealed)
        #expect(Export.skipReason(for: card(2), hit: hit(2, sealed: true)) == .sealed)

        let kept = card(1)
        kept.isPersonalCollection = true
        #expect(Export.skipReason(for: kept, hit: hit(1)) == .personal)

        let out = card(1)
        out.tags = ["at PSA"]
        #expect(Export.skipReason(for: out, hit: hit(1)) == .atGrader)

        let sold = card(1)
        sold.tags = ["sold"]
        #expect(Export.skipReason(for: sold, hit: hit(1)) == .sold)

        #expect(Export.skipReason(for: card(1), hit: nil) == .notInCatalog)

        let odd = card(1, condition: "Mint")
        #expect(Export.skipReason(for: odd, hit: hit(1)) == .unknownCondition)

        // He wants to test listing bulk, so bulk is listable.
        let bulk = card(1)
        bulk.isBulk = true
        bulk.quantity = 40
        #expect(Export.skipReason(for: bulk, hit: hit(1)) == nil)
    }

    @Test @MainActor func copiesOfOneSkuBecomeOneRow() throws {
        let prices: [Int: [ProductPrice]] = [
            1: [ProductPrice(subTypeName: "Holofoil", marketCents: 202, asOf: "2026-09-11")],
            2: [ProductPrice(subTypeName: "Normal", marketCents: 10, asOf: "2026-09-11"),
                ProductPrice(subTypeName: "Reverse Holofoil", marketCents: 40, asOf: "2026-09-11")],
        ]
        let bulk = card(1)
        bulk.quantity = 3
        let rows = [
            InventoryRow(card: card(1, condition: "Lightly Played"), hit: hit(1)),
            InventoryRow(card: card(1), hit: hit(1)),
            InventoryRow(card: bulk, hit: hit(1)),
            // No printing, and the product has only one: that one.
            InventoryRow(card: card(1, printing: ""), hit: hit(1)),
            // No printing, and the product has two: no guess.
            InventoryRow(card: card(2, printing: ""), hit: hit(2)),
        ]
        let plan = Export.plan(rows, prices: prices)

        #expect(plan.lines.count == 2)
        let nearMint = try #require(plan.lines.first)
        #expect(nearMint.key == .init(productId: 1, condition: "Near Mint", printing: "Holofoil", language: "English"))
        #expect(nearMint.quantity == 5)
        #expect(nearMint.cardIds.count == 3)
        #expect(nearMint.marketCents == 202)
        #expect(plan.lines.last?.key.condition == "Lightly Played")
        #expect(plan.skipped == [.noPrinting: 1])
        #expect(Export.skipReason(for: rows[4], prices: prices) == .noPrinting)
    }

    @Test @MainActor func aJapaneseCardAsksForTheJapaneseSku() {
        let prices = [3: [ProductPrice(subTypeName: "Holofoil", marketCents: 100, asOf: "2026-09-11")]]
        let plan = Export.plan([InventoryRow(card: card(3), hit: hit(3, category: TCGCategory.pokemonJapan))], prices: prices)
        #expect(plan.lines.first?.key.language == "Japanese")
    }

    // MARK: - Price

    @Test func theBuyersTotalMatchesTheCheapestTotal() {
        let low = TCGplayerMarketClient.Listing(skuId: 1, priceCents: 204, shippingCents: 149)

        let free = Export.price(lowest: low, marketCents: 202, shippingChargedCents: 0)
        #expect(free?.cents == 353)
        #expect(free?.source == .liveLow)

        #expect(Export.price(lowest: low, marketCents: 202, shippingChargedCents: 99)?.cents == 254)
        // TCGplayer rejects a price under a cent.
        #expect(Export.price(lowest: low, marketCents: 202, shippingChargedCents: 500)?.cents == 1)

        let market = Export.price(lowest: nil, marketCents: 202, shippingChargedCents: 99)
        #expect(market?.cents == 202)
        #expect(market?.source == .market)

        #expect(Export.price(lowest: nil, marketCents: nil, shippingChargedCents: 0) == nil)
        #expect(Export.price(lowest: nil, marketCents: 0, shippingChargedCents: 0) == nil)
    }

    // MARK: - The file

    @Test func theFileHasTheSixteenColumnsTheImportRequires() {
        var crobat = hit(232_613, set: "SWSH: Sword & Shield Promo Cards")
        crobat.name = "Crobat VMAX, promo"
        crobat.number = "SWSH099"
        crobat.rarity = "Promo"
        let key = Export.SkuKey(productId: 232_613, condition: "Near Mint", printing: "Holofoil", language: "English")
        let row = Export.Priced(
            line: .init(key: key, hit: crobat, quantity: 2, marketCents: 202, cardIds: []),
            skuId: 4_780_851, priceCents: 353, source: .liveLow,
            lowest: .init(skuId: 4_780_851, priceCents: 204, shippingCents: 149)
        )

        let lines = Export.csv([row], categoryNames: [3: "Pokemon"]).components(separatedBy: "\r\n")

        #expect(lines.count == 3)
        #expect(lines[0] == "TCGplayer Id,Product Line,Set Name,Product Name,Title,Number,Rarity,Condition,TCG Market Price,TCG Direct Low,TCG Low Price With Shipping,TCG Low Price,Total Quantity,Add to Quantity,TCG Marketplace Price,Photo URL")
        #expect(lines[1] == "4780851,Pokemon,SWSH: Sword & Shield Promo Cards,\"Crobat VMAX, promo\",,SWSH099,Promo,Near Mint Holofoil,2.02,,3.53,2.04,,2,3.53,")
        #expect(lines[2] == "")
    }

    @Test func theConditionReadsLikeTCGplayersOwnExport() {
        #expect(Export.conditionText(.init(productId: 1, condition: "Near Mint", printing: "Normal", language: "English")) == "Near Mint")
        #expect(Export.conditionText(.init(productId: 1, condition: "Lightly Played", printing: "Reverse Holofoil", language: "English")) == "Lightly Played Reverse Holofoil")
        #expect(Export.conditionText(.init(productId: 1, condition: "Near Mint", printing: "Holofoil", language: "Japanese")) == "Near Mint Holofoil - Japanese")
    }

    // MARK: - The run

    @Test @MainActor func aSkuNobodySellsTakesItsIdFromTheListAndItsMarketPrice() async {
        let sold = Export.SkuKey(productId: 1, condition: "Near Mint", printing: "Holofoil", language: "English")
        let unsold = Export.SkuKey(productId: 2, condition: "Lightly Played", printing: "Normal", language: "English")
        let unknown = Export.SkuKey(productId: 3, condition: "Near Mint", printing: "Normal", language: "English")
        let plan = Export.Plan(lines: [line(sold, market: 202), line(unsold, market: 150), line(unknown, market: 50)], skipped: [.slab: 2])
        let market = StubMarket(
            listings: [1: .init(skuId: 11, priceCents: 204, shippingCents: 149)],
            skuLists: [
                2: [.init(skuId: 21, condition: "Near Mint", printing: "Normal", language: "English"),
                    .init(skuId: 22, condition: "Lightly Played", printing: "Normal", language: "English")],
                3: [],
            ]
        )

        let outcome = await TCGplayerListingBuilder().build(plan, shippingChargedCents: 99, market: market, pause: .zero)

        #expect(outcome.rows.map(\.skuId) == [11, 22])
        #expect(outcome.rows.map(\.priceCents) == [254, 150])
        #expect(outcome.rows.map(\.source) == [.liveLow, .market])
        #expect(outcome.report.liveLow == 1)
        #expect(outcome.report.market == 1)
        #expect(outcome.report.noSku == 1)
        #expect(outcome.report.skipped == [.slab: 2])
    }

    @Test @MainActor func aRefusalStopsTheRun() async {
        let key = Export.SkuKey(productId: 1, condition: "Near Mint", printing: "Holofoil", language: "English")
        var other = key
        other.productId = 2
        let plan = Export.Plan(lines: [line(key, market: 100), line(other, market: 100)])

        let outcome = await TCGplayerListingBuilder().build(plan, shippingChargedCents: 0, market: StubMarket(refuse: true), pause: .zero)

        #expect(outcome.rows.isEmpty)
        #expect(outcome.report.stoppedBy == "TCGplayer answered 403")
        #expect(outcome.report.failed == 0)
    }

    // MARK: - Helpers

    private func hit(_ id: Int, set: String = "Set", sealed: Bool = false, category: Int = TCGCategory.pokemon) -> SearchHit {
        SearchHit(productId: id, groupId: 1, categoryId: category, name: "Card \(id)", cleanName: "card \(id)", setName: set, isSealed: sealed, printingCount: 1)
    }

    @MainActor
    private func card(_ productId: Int, printing: String = "Holofoil", condition: String = "Near Mint") -> OwnedCard {
        OwnedCard(productId: productId, printing: printing, condition: condition, confidence: .manual)
    }

    private func line(_ key: Export.SkuKey, market: Int?) -> Export.Line {
        Export.Line(key: key, hit: hit(key.productId), quantity: 1, marketCents: market, cardIds: [])
    }
}

private struct StubMarket: TCGplayerMarket {
    var listings: [Int: TCGplayerMarketClient.Listing] = [:]
    var skuLists: [Int: [TCGplayerMarketClient.Sku]] = [:]
    var refuse = false

    func cheapestListing(productId: Int, condition: String, printing: String, language: String) async throws -> TCGplayerMarketClient.Listing? {
        if refuse { throw TCGplayerMarketClient.Failure.http(403) }
        return listings[productId]
    }

    func skus(productId: Int) async throws -> [TCGplayerMarketClient.Sku] {
        skuLists[productId] ?? []
    }
}
