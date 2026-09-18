import Foundation
import GRDB

/// New prices for the sets he owns, straight from TCGCSV, without a catalog
/// publish on the Mac.
///
/// TCGCSV updates once a day and says when in `last-updated.txt`. Every price
/// row carries the date of the TCGCSV data it came from (`asOf`). So a refresh
/// is worth running only when TCGCSV's date is newer than the oldest `asOf`
/// among his cards, and the app allows it only then.
///
/// The refresh writes a copy of the live catalog and swaps the copy in, the
/// same as a download: the live file is never changed in place. New products
/// and artwork signatures still come only from the Mac publish.
enum PriceRefresh {
    static let lastUpdatedURL = URL(string: "https://tcgcsv.com/last-updated.txt")!
    /// TCGCSV answers 401 to some default user agents. The Mac build sends its
    /// own for the same reason.
    static let userAgent = "card-tracker-app/1.0 (+https://github.com/ajhollowayvrm/binderbooks)"
    /// Price files downloaded at the same time.
    static let parallelDownloads = 6

    struct PriceRow: Equatable, Sendable {
        var productId: Int
        var subTypeName: String
        var marketCents: Int?
        var lowCents: Int?
        var midCents: Int?
        var highCents: Int?
        var directLowCents: Int?
    }

    struct Group: Hashable, Sendable {
        var groupId: Int
        var categoryId: Int
    }

    enum Failure: LocalizedError, Equatable {
        case badResponse(Int)
        case unreadableDate(String)
        case unreadablePrices(Int)

        var errorDescription: String? {
            switch self {
            case .badResponse(let status): return "TCGCSV answered \(status)."
            case .unreadableDate(let text): return "TCGCSV sent a date the app cannot read: \(text)"
            case .unreadablePrices(let groupId): return "TCGCSV sent prices the app cannot read for set \(groupId)."
            }
        }
    }

    // MARK: - The source

    /// The UTC date of TCGCSV's last update, as YYYY-MM-DD: the same form as
    /// `asOf`, so the two compare as text.
    static func sourceDate() async throws -> String {
        let text = String(decoding: try await fetch(lastUpdatedURL), as: UTF8.self)
        guard let date = parseLastUpdated(text) else { throw Failure.unreadableDate(text) }
        return date
    }

    /// "2026-09-17T20:05:48+0000" to "2026-09-17". The same rule as
    /// `parse_last_updated` in catalog/build_catalog.py.
    static func parseLastUpdated(_ text: String) -> String? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        guard let stamp = parser.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return utcDay.string(from: stamp)
    }

    static func prices(for group: Group) async throws -> [PriceRow] {
        let url = URL(string: "https://tcgcsv.com/tcgplayer/\(group.categoryId)/\(group.groupId)/prices")!
        let data: Data
        do {
            data = try await fetch(url)
        } catch Failure.badResponse(404) {
            // TCGCSV answers 404 for a set with no prices, the same as an empty one.
            return []
        }
        guard let rows = parsePrices(data) else { throw Failure.unreadablePrices(group.groupId) }
        return rows
    }

    /// TCGCSV's `{"results": [...]}` to rows. Nil when the body is not that.
    static func parsePrices(_ data: Data) -> [PriceRow]? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = body["results"] as? [[String: Any]]
        else { return nil }
        return results.compactMap { item in
            guard let productId = (item["productId"] as? NSNumber)?.intValue,
                  let subTypeName = item["subTypeName"] as? String
            else { return nil }
            return PriceRow(
                productId: productId,
                subTypeName: subTypeName,
                marketCents: cents(item["marketPrice"]),
                lowCents: cents(item["lowPrice"]),
                midCents: cents(item["midPrice"]),
                highCents: cents(item["highPrice"]),
                directLowCents: cents(item["directLowPrice"])
            )
        }
    }

    /// A TCGCSV price to cents, rounded half up exactly once, the way
    /// `to_cents` in catalog/build_catalog.py does. The number goes through its
    /// shortest text form, "0.35", and never through `Double` arithmetic.
    static func cents(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        guard let decimal = Decimal(string: "\(number.doubleValue)", locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let behaviour = NSDecimalNumberHandler(
            roundingMode: .plain, scale: 0, raiseOnExactness: false,
            raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false
        )
        return NSDecimalNumber(decimal: decimal * 100).rounding(accordingToBehavior: behaviour).intValue
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.badResponse(http.statusCode)
        }
        return data
    }

    private static let utcDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - The catalog

    /// The products whose prices matter: his committed, unsold cards from the
    /// catalog. A sold card's price changes nothing.
    @MainActor
    static func productIds(of cards: [OwnedCard]) -> [Int] {
        Array(Set(cards.filter { $0.isCommitted && $0.isIdentified && !CardTagIndex.isSold($0) }.map(\.productId))).sorted()
    }

    /// The oldest price date among these products. Nil when none has a price.
    static func oldestPriceDate(_ db: Database, productIds: [Int]) throws -> String? {
        guard !productIds.isEmpty else { return nil }
        let placeholders = databaseQuestionMarks(count: productIds.count)
        return try String.fetchOne(
            db,
            sql: "SELECT min(asOf) FROM price WHERE productId IN (\(placeholders))",
            arguments: StatementArguments(productIds)
        )
    }

    /// The sets these products are in.
    static func groups(_ db: Database, productIds: [Int]) throws -> [Group] {
        guard !productIds.isEmpty else { return [] }
        let placeholders = databaseQuestionMarks(count: productIds.count)
        return try GRDB.Row.fetchAll(
            db,
            sql: "SELECT DISTINCT groupId, categoryId FROM product WHERE productId IN (\(placeholders)) ORDER BY groupId",
            arguments: StatementArguments(productIds)
        ).map { Group(groupId: $0["groupId"], categoryId: $0["categoryId"]) }
    }

    /// Replaces every price of the products in `groups` with `rows`, dated
    /// `asOf`. Writes the catalog file at `url`, which must be a copy.
    ///
    /// The old rows go first, so a printing TCGplayer stopped pricing does not
    /// keep a price, and the set's oldest `asOf` becomes today's. A row for a
    /// product the catalog does not hold is skipped: that card arrives with
    /// the next publish.
    static func apply(_ rows: [PriceRow], groups: [Group], asOf: String, to url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            let groupIds = groups.map(\.groupId)
            guard !groupIds.isEmpty else { return }
            let placeholders = databaseQuestionMarks(count: groupIds.count)
            try db.execute(
                sql: "DELETE FROM price WHERE productId IN (SELECT productId FROM product WHERE groupId IN (\(placeholders)))",
                arguments: StatementArguments(groupIds)
            )
            let insert = try db.makeStatement(sql: """
                INSERT OR REPLACE INTO price
                    (productId, subTypeName, marketPriceCents, lowPriceCents, midPriceCents, highPriceCents, directLowPriceCents, asOf)
                SELECT ?, ?, ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM product WHERE productId = ?)
                """)
            for row in rows {
                try insert.execute(arguments: [
                    row.productId, row.subTypeName, row.marketCents, row.lowCents, row.midCents,
                    row.highCents, row.directLowCents, asOf, row.productId,
                ])
            }
        }
        try queue.close()
    }
}
