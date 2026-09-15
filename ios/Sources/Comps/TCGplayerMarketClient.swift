import Foundation

/// What the listing export asks TCGplayer. A protocol, so the builder tests
/// run with no network.
protocol TCGplayerMarket: Sendable {
    func cheapestListing(productId: Int, condition: String, printing: String, language: String) async throws -> TCGplayerMarketClient.Listing?
    func details(productId: Int) async throws -> TCGplayerMarketClient.Details
}

/// TCGplayer's storefront endpoints: the ones its own product page calls.
///
/// They need no key. TCGplayer does not document them and can change them with
/// no warning, so every read is defensive and a failure stops with a status
/// code instead of guessing. Captured and verified on 2026-09-11.
///
/// The catalog cannot answer these questions. TCGCSV has no SKU endpoint, and
/// its prices are one row per printing, over every condition, once a day.
struct TCGplayerMarketClient: TCGplayerMarket {
    var session: URLSession = .shared

    static let base = URL(string: "https://mp-search-api.tcgplayer.com")!

    enum Failure: Error, Equatable {
        case http(Int)
        case unreadable
    }

    /// The cheapest live listing of one SKU.
    struct Listing: Equatable, Sendable {
        var skuId: Int
        var priceCents: Int
        /// What the buyer pays to ship this one card from that seller.
        var shippingCents: Int

        var totalCents: Int { priceCents + shippingCents }
    }

    /// One SKU: a product in one condition, printing, and language.
    struct Sku: Equatable, Sendable {
        var skuId: Int
        var condition: String
        var printing: String
        var language: String
    }

    /// A product the way TCGplayer's own page names it, with every SKU.
    struct Details: Equatable, Sendable {
        /// TCGplayer's exact name: "Yveltal ex - 053/088". Seller Portal's
        /// import rejects a row whose "Product Name" differs ("does not match
        /// product details"), and the catalog drops the number from the name.
        var productName: String?
        var skus: [Sku]
    }

    /// Ranked by price plus shipping, the order a buyer sees. Nil when nobody
    /// sells that SKU. The listing carries its SKU id, so a SKU with a listing
    /// needs no second call.
    func cheapestListing(productId: Int, condition: String, printing: String, language: String) async throws -> Listing? {
        var request = URLRequest(url: Self.base.appending(path: "v1/product/\(productId)/listings"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.listingsBody(condition: condition, printing: printing, language: language)
        request.timeoutInterval = 20
        return try Self.parseCheapest(try await send(request))
    }

    /// The product's exact name and every SKU. The SKUs are for a SKU that
    /// nobody sells.
    func details(productId: Int) async throws -> Details {
        var request = URLRequest(url: Self.base.appending(path: "v2/product/\(productId)/details"))
        request.timeoutInterval = 20
        return try Self.parseDetails(try await send(request))
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Failure.http(code) }
        return data
    }

    // MARK: - Request and parsing

    /// The filter TCGplayer's product page sends, narrowed to one SKU. Custom
    /// listings are left out: each is one seller's photographed copy, with
    /// its own description, and not the card the SKU describes.
    static func listingsBody(condition: String, printing: String, language: String) throws -> Data {
        let body: [String: Any] = [
            "filters": [
                "term": [
                    "sellerStatus": "Live",
                    "channelId": 0,
                    "language": [language],
                    "condition": [condition],
                    "printing": [printing],
                    "listingType": ["standard"],
                ],
                "range": ["quantity": ["gte": 1]],
                "exclude": ["channelExclusion": 0],
            ],
            "from": 0,
            "size": 1,
            "sort": ["field": "price+shipping", "order": "asc"],
            "context": ["shippingCountry": "US", "cart": [String: Any]()],
            "aggregations": ["listingType"],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func parseCheapest(_ data: Data) throws -> Listing? {
        guard let page = try? JSONDecoder().decode(ListingsEnvelope.self, from: data).results.first else {
            throw Failure.unreadable
        }
        guard let row = page.results.first else { return nil }
        guard let sku = row.productConditionId.flatMap({ Int(exactly: $0) }), let price = row.price else {
            throw Failure.unreadable
        }
        return Listing(skuId: sku, priceCents: cents(price), shippingCents: row.shippingPrice.map(cents) ?? 0)
    }

    static func parseDetails(_ data: Data) throws -> Details {
        guard let envelope = try? JSONDecoder().decode(DetailsEnvelope.self, from: data), let rows = envelope.skus else {
            throw Failure.unreadable
        }
        let skus = rows.compactMap { row in
            Int(exactly: row.sku).map { Sku(skuId: $0, condition: row.condition, printing: row.variant, language: row.language) }
        }
        return Details(productName: envelope.productName, skus: skus)
    }

    static func parseSkus(_ data: Data) throws -> [Sku] {
        try parseDetails(data).skus
    }

    /// Dollars to cents through `Decimal`, rounded to the nearest cent. The
    /// scale is explicit: the default handler does not round, and `intValue`
    /// then truncates 203.99999 to 203.
    static func cents(_ dollars: Decimal) -> Int {
        let nearest = NSDecimalNumberHandler(
            roundingMode: .plain, scale: 0,
            raiseOnExactness: false, raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false
        )
        return NSDecimalNumber(decimal: dollars * 100).rounding(accordingToBehavior: nearest).intValue
    }

    /// `{"results": [{"totalResults": 134, "results": [listing, …]}]}`. Ids
    /// arrive as JSON doubles (`4780851.0`).
    struct ListingsEnvelope: Decodable {
        var results: [Page]

        struct Page: Decodable {
            var results: [Row]
        }

        struct Row: Decodable {
            var productConditionId: Double?
            var price: Decimal?
            var shippingPrice: Decimal?
        }
    }

    struct DetailsEnvelope: Decodable {
        var productName: String?
        var skus: [Row]?

        struct Row: Decodable {
            var sku: Double
            var condition: String
            var variant: String
            var language: String
        }
    }
}
