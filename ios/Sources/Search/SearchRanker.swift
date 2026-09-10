import Foundation

/// Orders candidates. Pure, so the tests can pin the priority order from
/// docs/03: exact number, exact name, bm25, context boost, recency.
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
    static let contextBoost = 50.0
    static let trigramPenalty = 20.0

    static func score(_ candidate: Candidate, request: SearchRequest) -> Double {
        let hit = candidate.hit
        var score = 0.0

        if let fts = candidate.ftsRank {
            score += -fts
        } else if let tri = candidate.trigramRank {
            score += -tri - trigramPenalty
        }

        let query = request.trimmed
        let queryNumber = CollectorNumber.parse(query)
        if candidate.numberLookup || matchesNumber(hit, query: query, parsed: queryNumber) {
            score += exactNumberBoost
        }

        if !query.isEmpty, hit.cleanName == NameCleaner.clean(query) {
            score += exactNameBoost
        }

        switch request.context {
        case .buying where hit.isSealed:
            score += contextBoost
        case .intake where !hit.isSealed, .scanning where !hit.isSealed:
            score += contextBoost
        default:
            break
        }

        score += recency(hit.publishedOn)
        return score
    }

    static func rank(_ candidates: [Candidate], request: SearchRequest) -> [SearchHit] {
        candidates
            .map { ($0.hit, score($0, request: request)) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.productId < rhs.0.productId
            }
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
