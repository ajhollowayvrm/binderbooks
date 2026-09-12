import Foundation

/// Orders candidates. Pure, so the tests can pin the priority order from
/// docs/03: exact number, exact name, a number in a name, context, market
/// value, bm25, recency.
///
/// `SearchRequest.ranking` drops the value tier for the scanner, which needs
/// the closest name, not the dearest card.
///
/// Market value sits above bm25 on purpose. AJ reads a result list by price,
/// so the expensive printing must lead. Exact number, exact name, and the
/// context boost still outrank value, because a query that names one product
/// must return that product first.
enum SearchRanker {
    struct Candidate: Sendable {
        var hit: SearchHit
        /// bm25 from path A. Lower is better; FTS5 returns negative numbers.
        var ftsRank: Double?
        /// bm25 from path B.
        var trigramRank: Double?
        /// Found by the direct number lookup.
        var numberLookup: Bool = false
    }

    static let exactNumberBoost = 1_000.0
    static let exactNameBoost = 500.0
    static let numberInNameBoost = 250.0
    static let contextBoost = 50.0
    static let trigramPenalty = 20.0

    /// The sort keys of one candidate, most significant first. A larger key
    /// sorts earlier.
    struct SortKey: Comparable, Sendable {
        /// Exact number, exact name, and the context boost.
        var boost: Double
        /// The top market price over the product's printings, in cents. A
        /// product with no price is -1, so it sorts last.
        var valueCents: Int
        /// bm25, negated, with the trigram penalty applied.
        var relevance: Double
        /// Newer sets break ties.
        var recency: Double
        /// The last tiebreak. Negated, because a larger key sorts earlier and
        /// the lower productId must come first.
        var negatedProductId: Int

        static func < (lhs: SortKey, rhs: SortKey) -> Bool {
            if lhs.boost != rhs.boost { return lhs.boost < rhs.boost }
            if lhs.valueCents != rhs.valueCents { return lhs.valueCents < rhs.valueCents }
            if lhs.relevance != rhs.relevance { return lhs.relevance < rhs.relevance }
            if lhs.recency != rhs.recency { return lhs.recency < rhs.recency }
            return lhs.negatedProductId < rhs.negatedProductId
        }
    }

    static func sortKey(_ candidate: Candidate, request: SearchRequest) -> SortKey {
        let hit = candidate.hit
        var boost = 0.0

        let query = request.trimmed
        let queryNumber = CollectorNumber.parse(query)
        if candidate.numberLookup || matchesNumber(hit, query: query, parsed: queryNumber) {
            boost += exactNumberBoost
        }

        if !query.isEmpty, hit.cleanName == NameCleaner.clean(query) {
            boost += exactNameBoost
        }

        if matchesNumberInName(hit, query: query) {
            boost += numberInNameBoost
        }

        switch request.context {
        case .buying where hit.isSealed:
            boost += contextBoost
        case .intake where !hit.isSealed, .scanning where !hit.isSealed:
            boost += contextBoost
        default:
            break
        }

        var relevance = 0.0
        if let fts = candidate.ftsRank {
            relevance = -fts
        } else if let tri = candidate.trigramRank {
            relevance = -tri - trigramPenalty
        }

        return SortKey(
            boost: boost,
            // The scanner ranks by relevance instead. A $0.40 Cyndaquil must
            // outrank a $90 card that only looks like one.
            valueCents: request.ranking == .byValue ? value(hit) : 0,
            relevance: relevance,
            recency: recency(hit.publishedOn),
            negatedProductId: -hit.productId
        )
    }

    /// The price the list orders by: the product's top printing, the same
    /// number the row shows. A card with a $9,000 first edition is a $9,000
    /// card.
    static func value(_ hit: SearchHit) -> Int {
        hit.topMarketCents ?? -1
    }

    static func rank(_ candidates: [Candidate], request: SearchRequest) -> [SearchHit] {
        candidates
            .map { ($0.hit, sortKey($0, request: request)) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private static func matchesNumber(_ hit: SearchHit, query: String, parsed: CollectorNumber) -> Bool {
        guard let number = hit.number else { return false }
        if number.caseInsensitiveCompare(query) == .orderedSame { return true }
        guard let n = parsed.numberNum, n == hit.numberNum else { return false }
        if let total = parsed.setTotal { return total == hit.setTotal }
        if let code = parsed.setCode { return code == hit.setCode }
        return false
    }

    /// A name and a number, "pikachu 25" or "mew 151". The number is the card's
    /// collector number, or a word of its set's name. Either one outranks a
    /// card that only prefix-matches the digits somewhere: before this tier,
    /// "pikachu 25" put a card numbered 007/025 first because it was dearer.
    private static func matchesNumberInName(_ hit: SearchHit, query: String) -> Bool {
        let tokens = query.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count >= 2 else { return false }
        var setWords: Set<Substring>?
        for token in tokens where token.first?.isNumber == true {
            let parsed = CollectorNumber.parse(String(token))
            guard let n = parsed.numberNum else { continue }
            if n == hit.numberNum, parsed.setTotal == nil || parsed.setTotal == hit.setTotal {
                return true
            }
            if setWords == nil {
                setWords = Set(NameCleaner.clean(hit.setName).split(separator: " "))
            }
            if setWords?.contains(Substring(token.lowercased())) == true {
                return true
            }
        }
        return false
    }

    /// Newer sets break ties. Days since 2000 scaled to at most about one point.
    static func recency(_ publishedOn: String?) -> Double {
        guard let publishedOn, publishedOn.count >= 10 else { return 0 }
        let prefix = publishedOn.prefix(10)
        let parts = prefix.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return 0 }
        let days = Double((parts[0] - 2000) * 365 + (parts[1] - 1) * 30 + parts[2])
        return max(0, days) / 10_000
    }
}
