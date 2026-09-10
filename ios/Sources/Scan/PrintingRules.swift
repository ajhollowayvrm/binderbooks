import Foundation

/// Picks a printing without AI. One printing: assign it. Several: a rarity rule,
/// flagged as a guess. One table, easy to tune.
enum PrintingRules {
    struct Choice: Equatable {
        var printing: String
        var guessed: Bool
    }

    /// Preferred printing by rarity, in order of preference. The first one the
    /// product actually has wins.
    static let preferences: [(rarityContains: String, printings: [String])] = [
        ("common", ["Normal", "Reverse Holofoil"]),
        ("uncommon", ["Normal", "Reverse Holofoil"]),
        ("promo", ["Holofoil", "Normal"]),
        ("holo", ["Holofoil"]),
        ("double rare", ["Holofoil"]),
        ("ultra", ["Holofoil"]),
        ("illustration", ["Holofoil"]),
        ("special", ["Holofoil"]),
        ("hyper", ["Holofoil"]),
        ("secret", ["Holofoil"]),
        ("ace spec", ["Holofoil"]),
        ("rare", ["Holofoil", "Normal"]),
    ]

    static func choose(available: [String], rarity: String?, sessionDefault: String?) -> Choice {
        if available.count == 1 {
            return Choice(printing: available[0], guessed: false)
        }
        if available.isEmpty {
            return Choice(printing: sessionDefault ?? "Normal", guessed: false)
        }
        if let sessionDefault, available.contains(sessionDefault) {
            return Choice(printing: sessionDefault, guessed: false)
        }
        let lowered = (rarity ?? "").lowercased()
        for rule in preferences where lowered.contains(rule.rarityContains) {
            if let pick = rule.printings.first(where: { available.contains($0) }) {
                return Choice(printing: pick, guessed: true)
            }
        }
        return Choice(printing: available.contains("Normal") ? "Normal" : available[0], guessed: true)
    }
}
