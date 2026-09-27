import Foundation

/// The names he used before for who he bought from, sold through, graded
/// with, or paid. `CounterpartyField` offers them as a list.
///
/// The list comes from the store, so a new name joins it when he saves the
/// entry. Nothing else keeps the list.
enum Counterparties {
    /// One entry for each name, most used first, then alphabetical.
    ///
    /// Names that differ only by case are one name, because "Gamecraft" and
    /// "GameCraft" are one store. The spelling he used most is the one the
    /// list shows.
    static func names(_ values: [String]) -> [String] {
        var counts: [String: [String: Int]] = [:]
        for value in values {
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            counts[name.lowercased(), default: [:]][name, default: 0] += 1
        }
        let entries = counts.values.map { spellings -> (name: String, count: Int) in
            let name = spellings.max { lhs, rhs in
                lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
            }?.key ?? ""
            return (name, spellings.values.reduce(0, +))
        }
        return entries
            .sorted { $0.count == $1.count ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : $0.count > $1.count }
            .map(\.name)
    }

    /// Sale channels as the ledger shows them: "TCGplayer", not "tcgplayer".
    /// A save turns the name back into the stored key with
    /// `AddTransactionSheet.channelKey`.
    @MainActor
    static func channels(_ sales: [Sale]) -> [String] {
        names(sales.map { LedgerEntry.channelName($0.channelRaw) })
    }

    /// The name in `options` that `typed` means, ignoring case and spaces at
    /// the ends. Nil when he typed a new name.
    static func match(_ typed: String, in options: [String]) -> String? {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return options.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}
