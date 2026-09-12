import Foundation

/// Turns typed text into FTS5 MATCH strings. Pure functions.
enum SearchQueryBuilder {
    /// Path A. Every whitespace token becomes a quoted prefix phrase, and the
    /// tokens AND together: `"legendary"* AND "box"*`. Quoting means the user
    /// can type FTS operators, slashes, or apostrophes without breaking the query.
    ///
    /// A token can also match the way the catalog spells it. Each spelling is an
    /// OR alternative inside that token's group, so every token must still
    /// match something. FTS5 needs the explicit AND: it rejects an implicit one
    /// after a closing parenthesis.
    static func ftsMatch(_ text: String) -> String? {
        let tokens = text
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map(tokenMatch).joined(separator: " AND ")
    }

    /// Words people type that TCGplayer spells another way. Only two product
    /// names contain "ETB"; 321 contain "Elite Trainer Box".
    static let shortForms: [String: String] = [
        "etb": "elite trainer box",
        "upc": "ultra premium collection",
        "pokeball": "poke ball",
        "masterball": "master ball",
        // The only two names with an apostrophe-d. The index splits them.
        "farfetchd": "farfetch d",
        "sirfetchd": "sirfetch d",
    ]

    private static func tokenMatch(_ token: String) -> String {
        let lower = token.lowercased()
        var phrases = [token]
        if let long = shortForms[lower] {
            phrases.append(long)
        }
        // The index splits "N's" into "n" and "s". A possessive typed with no
        // apostrophe, "ns" or "lillies", is one token that matches nothing, so
        // offer the split form too.
        if lower.count >= 2, lower.hasSuffix("s"), lower.allSatisfy(\.isLetter) {
            phrases.append("\(lower.dropLast()) s")
        }
        // Collector numbers print with leading zeros, "025/165", and a typed
        // "25" does not prefix-match "025".
        if lower.count < 3, lower.allSatisfy({ $0.isASCII && $0.isNumber }) {
            phrases.append(String(repeating: "0", count: 3 - lower.count) + lower)
        }
        let quoted = phrases.map { "\"\($0)\"*" }
        return quoted.count == 1 ? quoted[0] : "(" + quoted.joined(separator: " OR ") + ")"
    }

    /// A printing word split off the query.
    struct PrintingQualifier: Equatable, Sendable {
        /// The rest of the query.
        var remainder: String
        /// The start of the printing's `subTypeName`, for example "1st Edition".
        var printing: String
    }

    private static let printingWords: [(pattern: Regex<Substring>, printing: String)] = [
        (#/\b(?:1st|first)\s+ed(?:ition)?\b/#.ignoresCase(), "1st Edition"),
        (#/\bunlimited\b/#.ignoresCase(), "Unlimited"),
    ]

    /// "1st edition charizard" names a printing, and TCGplayer records a
    /// printing as a price row, never in the product name. Nil when the query
    /// has no printing word, or has nothing else.
    static func printingQualifier(_ text: String) -> PrintingQualifier? {
        for word in printingWords {
            guard let match = text.firstMatch(of: word.pattern) else { continue }
            var rest = text
            rest.removeSubrange(match.range)
            let remainder = rest.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !remainder.isEmpty else { return nil }
            return PrintingQualifier(remainder: remainder, printing: word.printing)
        }
        return nil
    }

    /// Path B. The trigram tokenizer needs every trigram of a plain MATCH to
    /// exist in the row, so a typo returns nothing. OR the query's trigrams
    /// instead and let bm25 rank rows by how many they share.
    ///
    /// Each whitespace token gets its own OR group, and the groups AND
    /// together. Without this split, "Binacle promo" flattens to one bag of
    /// trigrams, and a common one like "rom" or "omo" matches every promo
    /// card in the catalog, not just Binacle's.
    static func trigramMatch(_ text: String) -> String? {
        let tokens = text
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.lowercased().replacingOccurrences(of: "\"", with: "") }
        let groups = tokens.compactMap(trigramTerms).filter { !$0.isEmpty }
        guard !groups.isEmpty else { return nil }
        if groups.count == 1 {
            return groups[0].joined(separator: " OR ")
        }
        return groups.map { "(" + $0.joined(separator: " OR ") + ")" }.joined(separator: " AND ")
    }

    /// The trigrams of one token, in first-seen order. Empty when the token
    /// is too short to have a trigram.
    private static func trigramTerms(_ token: String) -> [String] {
        let scalars = Array(token.unicodeScalars)
        guard scalars.count >= 3 else { return [] }
        var seen = Set<String>()
        var terms: [String] = []
        for i in 0...(scalars.count - 3) {
            var s = String.UnicodeScalarView()
            s.append(contentsOf: scalars[i..<(i + 3)])
            let trigram = String(s)
            if seen.insert(trigram).inserted {
                terms.append("\"\(trigram)\"")
            }
        }
        return terms
    }

    /// The trigram tokenizer needs three characters. Below that, path B is off.
    static let trigramMinimumLength = 3
}
