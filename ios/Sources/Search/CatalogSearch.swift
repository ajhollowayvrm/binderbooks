import Foundation
import GRDB

/// The one search component. Every flow is a thin wrapper around this.
struct CatalogSearch: Sendable {
    let database: CatalogDatabase

    static let candidateLimit = 200
    static let trigramLimit = 100
    static let browseLimit = 600

    /// Runs the query off the main actor.
    func search(_ request: SearchRequest) async throws -> [SearchHit] {
        let text = request.trimmed
        if text.isEmpty {
            guard request.filter.groupId != nil || request.filter.isActive else { return [] }
            return try await browse(request.filter)
        }
        return try await database.asyncRead { db in
            try Self.search(db, request: request)
        }
    }

    /// Synchronous body, so the tests can call it on a fixture database.
    static func search(_ db: Database, request: SearchRequest) throws -> [SearchHit] {
        let text = request.trimmed
        var candidates: [Int: SearchRanker.Candidate] = [:]

        // Path A: token and prefix.
        if let match = SearchQueryBuilder.ftsMatch(text) {
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT rowid, bm25(product_fts, 10.0, 5.0, 2.0) AS rank FROM product_fts WHERE product_fts MATCH ? ORDER BY rank LIMIT ?",
                arguments: [match, candidateLimit]
            )
            for row in rows {
                let id: Int = row["rowid"]
                candidates[id] = .init(hit: placeholder(id), ftsRank: row["rank"])
            }
        }

        // Path B: typo tolerance, only when A came back thin.
        if candidates.count < SearchQueryBuilder.trigramFallbackThreshold,
           text.count >= SearchQueryBuilder.trigramMinimumLength,
           let match = SearchQueryBuilder.trigramMatch(text) {
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT rowid, bm25(product_trigram) AS rank FROM product_trigram WHERE product_trigram MATCH ? ORDER BY rank LIMIT ?",
                arguments: [match, trigramLimit]
            )
            for row in rows {
                let id: Int = row["rowid"]
                if candidates[id] == nil {
                    candidates[id] = .init(hit: placeholder(id), trigramRank: row["rank"])
                } else {
                    candidates[id]?.trigramRank = row["rank"]
                }
            }
        }

        // Direct number lookup. The tokenizer splits "114/084" into two tokens,
        // and this path is exact where FTS is approximate.
        if CollectorNumber.looksLikeNumber(text) {
            let parsed = CollectorNumber.parse(text)
            var sql = "SELECT productId FROM product WHERE number = ? COLLATE NOCASE"
            var arguments: StatementArguments = [text]
            if let n = parsed.numberNum, let total = parsed.setTotal {
                sql += " OR (numberNum = ? AND setTotal = ?)"
                arguments += [n, total]
            } else if let n = parsed.numberNum, let code = parsed.setCode {
                sql += " OR (numberNum = ? AND setCode = ?)"
                arguments += [n, code]
            } else if let n = parsed.numberNum {
                sql += " OR numberNum = ?"
                arguments += [n]
            }
            sql += " LIMIT ?"
            arguments += [candidateLimit]
            for id in try Int.fetchAll(db, sql: sql, arguments: arguments) {
                if candidates[id] == nil {
                    candidates[id] = .init(hit: placeholder(id), numberLookup: true)
                } else {
                    candidates[id]?.numberLookup = true
                }
            }
        }

        guard !candidates.isEmpty else { return [] }
        let hits = try fetchHits(db, ids: Array(candidates.keys), filter: request.filter)
        let ranked = hits.compactMap { hit -> SearchRanker.Candidate? in
            guard var candidate = candidates[hit.productId] else { return nil }
            candidate.hit = hit
            return candidate
        }
        return SearchRanker.rank(ranked, request: request)
    }

    /// Empty query with a filter: list the set, or the filtered categories.
    func browse(_ filter: SearchFilter) async throws -> [SearchHit] {
        try await database.asyncRead { db in
            var sql = Self.hitSelect + " WHERE 1 = 1" + Self.filterClause(filter)
            sql += " ORDER BY p.isSealed, p.numberNum, p.name LIMIT ?"
            return try Self.hits(db, sql: sql, arguments: Self.filterArguments(filter) + [Self.browseLimit])
        }
    }

    func categories() async throws -> [CategorySummary] {
        try await database.asyncRead { db in
            try Row.fetchAll(db, sql: "SELECT categoryId, name, displayName FROM category ORDER BY categoryId").map {
                CategorySummary(categoryId: $0["categoryId"], name: $0["name"], displayName: $0["displayName"])
            }
        }
    }

    func sets() async throws -> [SetSummary] {
        try await database.asyncRead { db in
            let sql = """
            SELECT s.groupId, s.categoryId, c.name AS categoryName, s.name, s.abbreviation, s.publishedOn,
                   (SELECT count(*) FROM product p WHERE p.groupId = s.groupId) AS productCount
            FROM cardSet s JOIN category c ON c.categoryId = s.categoryId
            ORDER BY s.publishedOn DESC, s.name
            """
            return try Row.fetchAll(db, sql: sql).map {
                SetSummary(
                    groupId: $0["groupId"], categoryId: $0["categoryId"], categoryName: $0["categoryName"],
                    name: $0["name"], abbreviation: $0["abbreviation"], publishedOn: $0["publishedOn"],
                    productCount: $0["productCount"]
                )
            }
        }
    }

    func hits(ids: [Int]) async throws -> [SearchHit] {
        guard !ids.isEmpty else { return [] }
        return try await database.asyncRead { db in
            let found = try Self.fetchHits(db, ids: ids, filter: SearchFilter())
            let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
            return found.sorted { (order[$0.productId] ?? 0) < (order[$1.productId] ?? 0) }
        }
    }

    /// Every price row for the given products, keyed by productId.
    func prices(for ids: [Int]) async throws -> [Int: [ProductPrice]] {
        guard !ids.isEmpty else { return [:] }
        return try await database.asyncRead { db in
            let placeholders = ids.map { String($0) }.joined(separator: ",")
            var out: [Int: [ProductPrice]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT productId, subTypeName, marketPriceCents, lowPriceCents, midPriceCents, highPriceCents, directLowPriceCents, asOf FROM price WHERE productId IN (\(placeholders)) ORDER BY subTypeName") {
                let price = ProductPrice(
                    subTypeName: row["subTypeName"], marketCents: row["marketPriceCents"], lowCents: row["lowPriceCents"],
                    midCents: row["midPriceCents"], highCents: row["highPriceCents"], directLowCents: row["directLowPriceCents"],
                    asOf: row["asOf"]
                )
                out[row["productId"], default: []].append(price)
            }
            return out
        }
    }

    func detail(productId: Int) async throws -> ProductDetail? {
        try await database.asyncRead { db in
            guard let hit = try Self.fetchHits(db, ids: [productId], filter: SearchFilter()).first else { return nil }
            let extra = try Row.fetchOne(
                db,
                sql: "SELECT p.cardType, s.abbreviation, c.name AS categoryName FROM product p JOIN cardSet s ON s.groupId = p.groupId JOIN category c ON c.categoryId = p.categoryId WHERE p.productId = ?",
                arguments: [productId]
            )
            let prices = try Row.fetchAll(
                db,
                sql: "SELECT subTypeName, marketPriceCents, lowPriceCents, midPriceCents, highPriceCents, directLowPriceCents, asOf FROM price WHERE productId = ? ORDER BY subTypeName",
                arguments: [productId]
            ).map {
                ProductPrice(
                    subTypeName: $0["subTypeName"], marketCents: $0["marketPriceCents"], lowCents: $0["lowPriceCents"],
                    midCents: $0["midPriceCents"], highCents: $0["highPriceCents"], directLowCents: $0["directLowPriceCents"],
                    asOf: $0["asOf"]
                )
            }
            return ProductDetail(
                hit: hit,
                categoryName: extra?["categoryName"] ?? "",
                cardType: extra?["cardType"],
                setAbbreviation: extra?["abbreviation"],
                prices: prices
            )
        }
    }

    // MARK: - SQL

    private static let hitSelect = """
    SELECT p.productId, p.groupId, p.categoryId, p.name, p.cleanName, p.imageUrl, p.number, p.numberNum,
           p.setTotal, p.setCode, p.rarity, p.isSealed, p.printingCount,
           s.name AS setName, s.publishedOn,
           (SELECT min(marketPriceCents) FROM price WHERE price.productId = p.productId) AS minMarket,
           (SELECT max(marketPriceCents) FROM price WHERE price.productId = p.productId) AS maxMarket
    FROM product p JOIN cardSet s ON s.groupId = p.groupId
    """

    private static func filterClause(_ filter: SearchFilter) -> String {
        var sql = ""
        switch filter.kind {
        case .all: break
        case .singles: sql += " AND p.isSealed = 0"
        case .sealed: sql += " AND p.isSealed = 1"
        }
        if !filter.categoryIds.isEmpty {
            sql += " AND p.categoryId IN (\(filter.categoryIds.sorted().map(String.init).joined(separator: ",")))"
        }
        if filter.groupId != nil {
            sql += " AND p.groupId = ?"
        }
        return sql
    }

    private static func filterArguments(_ filter: SearchFilter) -> StatementArguments {
        if let groupId = filter.groupId { return [groupId] }
        return []
    }

    static func fetchHits(_ db: Database, ids: [Int], filter: SearchFilter) throws -> [SearchHit] {
        let placeholders = ids.map { String($0) }.joined(separator: ",")
        let sql = hitSelect + " WHERE p.productId IN (\(placeholders))" + filterClause(filter)
        return try hits(db, sql: sql, arguments: filterArguments(filter))
    }

    private static func hits(_ db: Database, sql: String, arguments: StatementArguments) throws -> [SearchHit] {
        try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
            SearchHit(
                productId: row["productId"], groupId: row["groupId"], categoryId: row["categoryId"],
                name: row["name"], cleanName: row["cleanName"], setName: row["setName"],
                number: row["number"], numberNum: row["numberNum"], setTotal: row["setTotal"], setCode: row["setCode"],
                rarity: row["rarity"], isSealed: (row["isSealed"] as Int) == 1, printingCount: row["printingCount"],
                imageUrl: row["imageUrl"], publishedOn: row["publishedOn"],
                minMarketCents: row["minMarket"], maxMarketCents: row["maxMarket"]
            )
        }
    }

    private static func placeholder(_ id: Int) -> SearchHit {
        SearchHit(productId: id, groupId: 0, categoryId: 0, name: "", cleanName: "", setName: "", isSealed: false, printingCount: 1)
    }
}
