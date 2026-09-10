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
    static func trigramMatch(_ text: String) -> String? {
        let lowered = text.lowercased().replacingOccurrences(of: "\"", with: "")
        let scalars = Array(lowered.unicodeScalars)
        guard scalars.count >= 3 else { return nil }
        var seen = Set<String>()
        var terms: [String] = []
        for i in 0...(scalars.count - 3) {
            var s = String.UnicodeScalarView()
            s.append(contentsOf: scalars[i..<(i + 3)])
            let trigram = String(s)
            if trigram.trimmingCharacters(in: .whitespaces).count < 2 { continue }
            if seen.insert(trigram).inserted {
                terms.append("\"\(trigram)\"")
            }
        }
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: " OR ")
    }

    /// The trigram tokenizer needs three characters. Below that, path B is off.
    static let trigramMinimumLength = 3

    /// Path B runs when path A returns fewer hits than this.
    static let trigramFallbackThreshold = 5
}
