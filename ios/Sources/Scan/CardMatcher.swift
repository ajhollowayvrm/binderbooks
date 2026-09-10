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
/// 2. Candidates by (setCode, numberNum) or (setTotal, numberNum).
/// 3. Add name candidates when the number gave nothing, or when several cards
///    share the total and none of them is the name he read.
/// 4. Score by name agreement, the session bias, an exact number string, and a
///    bonus where the number and the name agree.
/// 5. One candidate: certain. One clear winner: likely. Several: uncertain.
///    Nothing that agrees with the name: no product at all.
struct CardMatcher: Sendable {
    let database: CatalogDatabase

    static let nameAgreement = 0.5
    static let clearWinnerGap = 0.25
    static let recentBias = 0.3
    /// Added when the number and the name pick the same card.
    static let agreementBonus = 0.2
    static let olderBias = 0.15
    static let candidateCap = 12

    func match(_ observation: ScanObservation, session bias: [Int], defaultPrinting: String?) async throws -> MatchResult {
        try await database.asyncRead { db in
            try Self.match(db, observation: observation, bias: bias, defaultPrinting: defaultPrinting)
        }
    }

    static func match(_ db: Database, observation: ScanObservation, bias: [Int], defaultPrinting: String?) throws -> MatchResult {
        let parsed = CollectorNumber.parse(observation.number)
        let cleanedName = observation.name.map(NameCleaner.clean).flatMap { $0.isEmpty ? nil : $0 }

        let numberHits = try numberCandidates(db, parsed: parsed)
        let numberBest = cleanedName.map { name in
            numberHits.map { Similarity.dice(name, $0.cleanName) }.max() ?? 0
        }

        // Run the name search when the number gave nothing, and also when
        // several cards share the printed total and none of them is the name he
        // read. Many sets share a total, so an ambiguous number plus a
        // disagreeing name is how "Cyndaquil" came back as "Combusken".
        var nameHits: [SearchHit] = []
        if let name = observation.name, numberHits.isEmpty || (numberBest ?? 0) < nameAgreement {
            nameHits = try nameCandidates(db, name: name)
        }

        let numberIds = Set(numberHits.map(\.productId))
        let nameIds = Set(nameHits.map(\.productId))
        var merged: [SearchHit] = numberHits
        for hit in nameHits where !numberIds.contains(hit.productId) {
            merged.append(hit)
        }
        guard !merged.isEmpty else {
            return MatchResult(productId: nil, confidence: .uncertain, candidates: [], printing: defaultPrinting ?? "", printingGuessed: false)
        }

        let scored = merged.map { hit -> Candidate in
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
            // The number and the name point at the same card. That is the
            // strongest signal the scanner ever gets.
            let fromNumber = numberIds.contains(hit.productId)
            let fromName = nameIds.contains(hit.productId)
            if fromNumber, fromName { score += agreementBonus }
            return Candidate(hit: hit, score: score, similarity: similarity, fromNumber: fromNumber, fromName: fromName)
        }.sorted { $0.score > $1.score }

        let ordered = scored.map(\.hit)
        let top = scored[0]

        // Nothing he read agrees with anything on offer. Assign no product and
        // let the chip ask. A wrong card that looks confident is worse than a
        // card marked unknown.
        if cleanedName != nil, scored.count > 1, top.similarity < nameAgreement {
            return MatchResult(
                productId: nil,
                confidence: .uncertain,
                candidates: Array(ordered.prefix(candidateCap)),
                printing: defaultPrinting ?? "",
                printingGuessed: false
            )
        }

        var confidence: MatchConfidence
        if top.fromNumber, top.fromName, top.similarity >= nameAgreement {
            confidence = .certain
        } else if scored.count == 1 {
            if top.fromNumber {
                confidence = (cleanedName == nil || top.similarity >= nameAgreement) ? .certain : .likely
            } else {
                confidence = top.similarity >= 0.8 ? .likely : .uncertain
            }
        } else {
            let gap = top.score - scored[1].score
            if top.fromNumber, nameHits.isEmpty {
                confidence = gap >= clearWinnerGap ? .likely : .uncertain
            } else {
                confidence = (gap >= clearWinnerGap && top.similarity >= nameAgreement) ? .likely : .uncertain
            }
        }

        // The name won, and the number pointed at a different card. Two signals
        // disagree, so the chip must ask rather than assert. This is the
        // Cyndaquil case: a total misread off the card matched one Combusken.
        if !numberHits.isEmpty, !top.fromNumber, cleanedName != nil {
            confidence = .uncertain
        }

        let product = top.hit
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

    private struct Candidate {
        var hit: SearchHit
        var score: Double
        var similarity: Double
        var fromNumber: Bool
        var fromName: Bool
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
        // By relevance, not by value. The candidate cap must never drop the
        // closest name in favour of a dearer card that reads like it.
        let request = SearchRequest(text: name, context: .scanning, filter: filter, ranking: .byRelevance)
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
