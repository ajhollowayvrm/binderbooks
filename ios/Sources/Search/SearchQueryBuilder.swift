import Foundation

/// Turns typed text into FTS5 MATCH strings. Pure functions.
enum SearchQueryBuilder {
    /// Path A. Every whitespace token becomes a quoted prefix phrase, joined
    /// by the implicit AND: `"legendary"* "warriors"*`. Quoting means the user
    /// can type FTS operators, slashes, or apostrophes without breaking the query.
    static func ftsMatch(_ text: String) -> String? {
        let tokens = text
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
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
