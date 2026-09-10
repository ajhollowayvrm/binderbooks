import Foundation
import GRDB

/// What the matcher decided for one observation.
struct MatchResult: Equatable, Sendable {
    var productId: Int?
    var confidence: MatchConfidence
    /// Everything considered, best first. Feeds the disambiguation chip.
    var candidates: [SearchHit]
    var printing: String
    /// True when a rarity rule chose the printing among several.
    var printingGuessed: Bool

    var hit: SearchHit? { candidates.first { $0.productId == productId } }
}

/// Resolves an observation to a catalog product. Follows docs/03:
///
/// 1. Parse the number. The denominator carries the set.
/// 2. Candidates by (setCode, numberNum) or (setTotal, numberNum). Neither: name only.
/// 3. Narrow by the OCR name against cleanName, fuzzily.
/// 4. Apply the session bias.
/// 5. One candidate: certain. One clear winner: likely. Several: uncertain.
struct CardMatcher: Sendable {
    let database: CatalogDatabase

    static let nameAgreement = 0.5
    static let clearWinnerGap = 0.25
    static let recentBias = 0.3
    static let olderBias = 0.15
    static let candidateCap = 12

    func match(_ observation: ScanObservation, session bias: [Int], defaultPrinting: String?) async throws -> MatchResult {
        try await database.asyncRead { db in
            try Self.match(db, observation: observation, bias: bias, defaultPrinting: defaultPrinting)
        }
    }

    static func match(_ db: Database, observation: ScanObservation, bias: [Int], defaultPrinting: String?) throws -> MatchResult {
        let parsed = CollectorNumber.parse(observation.number)
        var candidates = try numberCandidates(db, parsed: parsed)
        var byNumber = !candidates.isEmpty

        if candidates.isEmpty, let name = observation.name {
            candidates = try nameCandidates(db, name: name)
            byNumber = false
        }
        guard !candidates.isEmpty else {
            return MatchResult(productId: nil, confidence: .uncertain, candidates: [], printing: defaultPrinting ?? "", printingGuessed: false)
        }

        let cleanedName = observation.name.map(NameCleaner.clean)
        let scored = candidates.map { hit -> (SearchHit, Double, Double) in
            let similarity = cleanedName.map { Similarity.dice($0, hit.cleanName) } ?? 0
            var score = similarity
            if let index = bias.firstIndex(of: hit.groupId) {
                score += index < 3 ? recentBias : olderBias
            }
            // An exact number string beats a loose numeric match.
            if let number = observation.number, let hitNumber = hit.number,
               number.caseInsensitiveCompare(hitNumber) == .orderedSame {
                score += 0.1
            }
            return (hit, score, similarity)
        }.sorted { $0.1 > $1.1 }

        let ordered = scored.map(\.0)
        let top = scored[0]
        var confidence: MatchConfidence
        if scored.count == 1 {
            if byNumber {
                confidence = (cleanedName == nil || top.2 >= nameAgreement) ? .certain : .likely
            } else {
                confidence = top.2 >= 0.8 ? .likely : .uncertain
            }
        } else {
            let gap = top.1 - scored[1].1
            if byNumber {
                confidence = gap >= clearWinnerGap ? .likely : .uncertain
            } else {
                confidence = (gap >= clearWinnerGap && top.2 >= nameAgreement) ? .likely : .uncertain
            }
        }

        let product = top.0
        let printings = try availablePrintings(db, productId: product.productId)
        let choice = PrintingRules.choose(available: printings, rarity: product.rarity, sessionDefault: defaultPrinting)
        if choice.guessed && confidence != .uncertain {
            confidence = .uncertain
        }

        return MatchResult(
            productId: product.productId,
            confidence: confidence,
            candidates: Array(ordered.prefix(candidateCap)),
            printing: choice.printing,
            printingGuessed: choice.guessed
        )
    }

    /// Re-resolve a card inside one set by its number. Used by review's
    /// "reassign to set". Returns nil when the set has no such number.
    static func product(_ db: Database, inGroup groupId: Int, numberNum: Int) throws -> SearchHit? {
        let ids = try Int.fetchAll(db, sql: "SELECT productId FROM product WHERE groupId = ? AND numberNum = ? ORDER BY isSealed, productId", arguments: [groupId, numberNum])
        guard let first = ids.first else { return nil }
        return try CatalogSearch.fetchHits(db, ids: [first], filter: SearchFilter()).first
    }

    static func availablePrintings(_ db: Database, productId: Int) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT subTypeName FROM price WHERE productId = ? ORDER BY subTypeName", arguments: [productId])
    }

    private static func numberCandidates(_ db: Database, parsed: CollectorNumber) throws -> [SearchHit] {
        guard let n = parsed.numberNum else { return [] }
        var ids: [Int]
        if let code = parsed.setCode {
            ids = try Int.fetchAll(db, sql: "SELECT productId FROM product WHERE setCode = ? AND numberNum = ? AND isSealed = 0 LIMIT 50", arguments: [code, n])
        } else if let total = parsed.setTotal {
            ids = try Int.fetchAll(db, sql: "SELECT productId FROM product WHERE setTotal = ? AND numberNum = ? AND isSealed = 0 LIMIT 50", arguments: [total, n])
        } else {
            return []
        }
        guard !ids.isEmpty else { return [] }
        return try CatalogSearch.fetchHits(db, ids: ids, filter: SearchFilter())
    }

    private static func nameCandidates(_ db: Database, name: String) throws -> [SearchHit] {
        var filter = SearchFilter()
        filter.kind = .singles
        let request = SearchRequest(text: name, context: .scanning, filter: filter)
        return Array(try CatalogSearch.search(db, request: request).prefix(candidateCap))
    }
}

enum Similarity {
    /// Sørensen–Dice over character bigrams. Tolerant of OCR misreads and of a
    /// suffix like "ex" that one side lacks. 1 is identical, 0 is disjoint.
    static func dice(_ a: String, _ b: String) -> Double {
        let x = bigrams(a)
        let y = bigrams(b)
        guard !x.isEmpty, !y.isEmpty else { return a == b ? 1 : 0 }
        var counts: [String: Int] = [:]
        for g in x { counts[g, default: 0] += 1 }
        var shared = 0
        for g in y {
            if let c = counts[g], c > 0 {
                counts[g] = c - 1
                shared += 1
            }
        }
        return 2.0 * Double(shared) / Double(x.count + y.count)
    }

    private static func bigrams(_ s: String) -> [String] {
        let chars = Array(s.replacingOccurrences(of: " ", with: ""))
        guard chars.count >= 2 else { return chars.map(String.init) }
        return (0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) }
    }
}
