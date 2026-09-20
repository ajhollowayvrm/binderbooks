import Foundation
import GRDB

/// The set code printed on a card, resolved to the sets that wear it.
///
/// The catalog already holds this mapping, in `cardSet.abbreviation`: "MEP" is
/// "ME: Mega Evolution Promo". Two things kept it out of reach.
///
/// 1. Only the scanner ever read it. The search field matched a typed code
///    against `product.setCode`, which the promo and the Energy sets leave
///    empty — all 141 Mega Evolution Promo cards carry a bare "001". So the
///    scanner could find a card by "MEP 015" and the search field could not,
///    and a bare "MEP" returned four Digimon cards named Mephistomon.
/// 2. Both matches were case sensitive, and `CollectorNumber` uppercases every
///    code it parses. The Japanese sets are written "SV4a", "S1a", "sA", "mEZ",
///    so no Japanese set whose code ends in a lowercase letter could ever be
///    matched by its code, in the search field or in the scanner.
///
/// A code is not unique. "PR" is 21 different sets, from WoTC Promo to Jumbo
/// Cards, and "POP" is 9. So this returns every set that wears the code and
/// lets the ranker order them. It never picks one, and it never filters
/// anything out of the candidates — the same rule the rip set scope follows.
enum SetCodeIndex {
    /// Starts with a letter, then letters and digits, six characters at most.
    /// "MEP", "SV4a", "sA". A longer word is a name, and "151" is a number.
    private static let shape = #/^[A-Za-z][A-Za-z0-9]{1,5}$/#

    static func looksLikeCode(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).wholeMatch(of: shape) != nil
    }

    /// Every set wearing this code, whatever its case.
    static func groupIds(_ db: Database, code: String) throws -> [Int] {
        try Int.fetchAll(
            db,
            sql: "SELECT groupId FROM cardSet WHERE abbreviation = ? COLLATE NOCASE",
            arguments: [code]
        )
    }

    /// The name of each set wearing this code. For a label, and for the tests.
    static func setNames(_ db: Database, code: String) throws -> [String] {
        try String.fetchAll(
            db,
            sql: "SELECT name FROM cardSet WHERE abbreviation = ? COLLATE NOCASE ORDER BY name",
            arguments: [code]
        )
    }

    /// The cards of every set wearing this code, dearest first.
    ///
    /// Dearest first because the code is all he typed. "PR" is thousands of
    /// cards across 21 sets and the cap has to fall somewhere; the $400 promo
    /// is a better guess at what he means than whichever card sorts first by
    /// rowid. The ranker still reorders what comes back.
    static func productIds(_ db: Database, code: String, limit: Int) throws -> [Int] {
        try Int.fetchAll(db, sql: """
            SELECT p.productId FROM product p
            WHERE p.isSealed = 0
              AND p.groupId IN (SELECT groupId FROM cardSet WHERE abbreviation = ? COLLATE NOCASE)
            ORDER BY (SELECT max(marketPriceCents) FROM price WHERE price.productId = p.productId) IS NULL,
                     (SELECT max(marketPriceCents) FROM price WHERE price.productId = p.productId) DESC
            LIMIT ?
            """, arguments: [code, limit])
    }
}
