import Foundation

/// One parsed query, reused across every card in the pass.
struct OwnedCardQuery: Equatable, Sendable {
    /// The query, cleaned and split. Every token must appear in the haystack.
    let tokens: [String]
    /// The trimmed, lower-case query. Used for the cert-number rule.
    let raw: String
    let number: CollectorNumber
    let isNumber: Bool

    var isEmpty: Bool { tokens.isEmpty && raw.isEmpty }

    init(_ text: String) {
        raw = text.trimmingCharacters(in: .whitespaces).lowercased()
        tokens = NameCleaner.clean(text).split(separator: " ").map(String.init)
        number = CollectorNumber.parse(text)
        isNumber = CollectorNumber.looksLikeNumber(text)
    }
}

/// Matches one owned card against a typed query.
///
/// The collection store holds no card name (`docs/02-data-model.md`), so a name
/// match reads the catalog `SearchHit` that `InventoryModel` caches per
/// `productId`. A card with no hit is not yet identified; it then matches on
/// the scanner's text, the cert number, the printing, the condition, and the
/// tags only.
///
/// There is no fuzzy score here. Typo tolerance belongs to the catalog trigram
/// path. He knows what is in his own collection, and a fuzzy match would put
/// cards he did not ask for above the cards he did.
enum OwnedCardMatcher {
    /// Everything about one card that a query may match, cleaned once.
    static func haystack(card: OwnedCard, hit: SearchHit?) -> String {
        var parts: [String] = []
        if let hit {
            parts.append(hit.cleanName)
            parts.append(NameCleaner.clean(hit.setName))
            if let number = hit.number { parts.append(number) }
            if let code = hit.setCode { parts.append(code) }
            if let rarity = hit.rarity { parts.append(NameCleaner.clean(rarity)) }
        }
        if !card.printing.isEmpty { parts.append(NameCleaner.clean(card.printing)) }
        parts.append(NameCleaner.clean(CardCondition(rawValue: card.condition)?.short ?? card.condition))
        if let ocrName = card.ocrName { parts.append(NameCleaner.clean(ocrName)) }
        if let ocrNumber = card.ocrNumber { parts.append(ocrNumber) }
        if let cert = card.certNumber { parts.append(cert) }
        if let grader = card.graderRaw { parts.append(NameCleaner.clean(grader)) }
        if let grade = card.gradeLabel { parts.append(NameCleaner.clean(grade)) }
        // The tag hook. A label he typed reaches the one search field here.
        parts.append(contentsOf: card.tags.map(NameCleaner.clean))
        return parts.joined(separator: " ").lowercased()
    }

    static func matches(haystack: String, card: OwnedCard, hit: SearchHit?, query: OwnedCardQuery) -> Bool {
        if query.isEmpty { return true }

        if !query.tokens.isEmpty, query.tokens.allSatisfy({ haystack.contains($0) }) { return true }

        if query.isNumber, matchesNumber(card: card, hit: hit, query: query.number) { return true }

        // He reads the last digits off a slab label.
        if !query.raw.isEmpty, let cert = card.certNumber, cert.lowercased().contains(query.raw) { return true }

        return false
    }

    private static func matchesNumber(card: OwnedCard, hit: SearchHit?, query: CollectorNumber) -> Bool {
        guard let wanted = query.numberNum else { return false }
        if let hit, hit.numberNum == wanted {
            if let total = query.setTotal { return total == hit.setTotal }
            if let code = query.setCode { return code == hit.setCode }
            return true
        }
        // An unidentified card still answers a number query through the scan.
        let scanned = CollectorNumber.parse(card.ocrNumber)
        guard scanned.numberNum == wanted else { return false }
        if let total = query.setTotal { return total == scanned.setTotal }
        if let code = query.setCode { return code == scanned.setCode }
        return true
    }
}
