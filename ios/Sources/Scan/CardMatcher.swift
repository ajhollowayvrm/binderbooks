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
    /// The bar a name must clear when it is the **only** signal.
    ///
    /// With no number, a loose name match is the whole decision, and a loose
    /// match is how an attack name became a card. "Scratch" against
    /// "Scramble Switch" scores 0.53 and cleared `nameAgreement`, so a Sableye
    /// was logged twice as a Japanese trainer. Below this bar the matcher
    /// assigns nothing and the chip asks. docs/03: a wrong card that looks
    /// confident is worse than a card marked unknown.
    static let nameOnlyAgreement = 0.75
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
        let numberHits = try numberCandidates(db, parsed: parsed)

        // Which line on the card is its name? The frame cannot tell, so every
        // plausible line is tried and the catalog decides: an attack name is
        // not a card name, and the catalog holds every card name there is.
        let (chosenName, nameHits) = try readName(db, observation: observation, numberHits: numberHits)
        let cleanedName = chosenName.map(NameCleaner.clean).flatMap { $0.isEmpty ? nil : $0 }

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

        // A weak name must never beat the number.
        //
        // Scoring ranks by name similarity, so a junk reading can outrank the
        // right card: "scratch" scores 0.53 against "scramble switch" and 0.00
        // against "sableye", which is how a Sableye held over its own number
        // came back as a Japanese trainer. docs/03: a name the catalog does not
        // hold cannot overrule the number, because glare and attack text
        // produce readings like that and the number is still right.
        if cleanedName != nil, !top.fromNumber, top.similarity < nameOnlyAgreement {
            // The number's cards lead the chip. He is far likelier to want one
            // of those than the card a misread name dragged in.
            let byNumber = scored.filter(\.fromNumber)
            let chip = (byNumber + scored.filter { !$0.fromNumber }).map(\.hit)
            // Assign nothing. Neither signal can be trusted: the name is junk,
            // and a number with no name to corroborate it is one misread digit
            // away from a real card in another set. 070/196 is a Sableye in
            // Lost Origin and 070/195 is a Mawile V in Silver Tempest, so
            // "exactly one card carries this number" is not the safety it looks
            // like. docs/03: a wrong card that looks confident is worse than a
            // card marked unknown.
            return MatchResult(
                productId: nil,
                confidence: .uncertain,
                candidates: Array(chip.prefix(candidateCap)),
                printing: defaultPrinting ?? "",
                printingGuessed: false
            )
        }

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

    /// The line that reads best as a card name, and what it found.
    ///
    /// Each candidate is scored by how well the catalog's answer matches the
    /// line itself. "Sableye" finds a card called Sableye and scores 1.0.
    /// "Scratch" finds a Scramble Switch and scores 0.53, so it loses to any
    /// line that names a real card. A line agreeing with the number wins
    /// outright, because that is two signals pointing the same way.
    static func readName(_ db: Database, observation: ScanObservation, numberHits: [SearchHit]) throws -> (String?, [SearchHit]) {
        let lines = observation.nameCandidates.isEmpty
            ? [observation.name].compactMap { $0 }
            : observation.nameCandidates
        guard !lines.isEmpty else { return (nil, []) }

        // The catalog holds every card name there is, so membership settles it
        // outright: "Sableye" is a card and "Scratch" is not. The lines arrive
        // best-first, so the first real card name wins.
        for line in lines {
            let cleaned = NameCleaner.clean(line)
            guard !cleaned.isEmpty, try isACardName(db, cleaned) else { continue }
            if numberHits.contains(where: { $0.cleanName == cleaned }) {
                // The line names one of the number's cards. Two signals agree.
                return (line, [])
            }
            return (line, try nameCandidates(db, name: line))
        }

        // Nothing he read is a card name. Fall back to the closest fuzzy match,
        // because OCR misreads a name as often as it reads the wrong line.
        var best: (line: String, hits: [SearchHit], score: Double)?
        for line in lines {
            let cleaned = NameCleaner.clean(line)
            guard !cleaned.isEmpty else { continue }

            // A line that names one of the number's cards settles it.
            if let agreeing = numberHits.map({ Similarity.dice(cleaned, $0.cleanName) }).max(), agreeing >= nameAgreement {
                return (line, [])
            }

            let hits = try nameCandidates(db, name: line)
            let score = hits.map { Similarity.dice(cleaned, $0.cleanName) }.max() ?? 0
            if best == nil || score > best!.score {
                best = (line, hits, score)
            }
        }
        guard let best else { return (lines.first, []) }
        return (best.line, best.hits)
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

    /// True when the catalog holds a single card by exactly this name.
    /// Backed by `idx_product_clean`, so it is one indexed lookup per line.
    static func isACardName(_ db: Database, _ cleanName: String) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS (SELECT 1 FROM product WHERE cleanName = ? AND isSealed = 0)",
            arguments: [cleanName]
        ) ?? false
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
