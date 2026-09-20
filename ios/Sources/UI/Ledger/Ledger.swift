import Foundation
import SwiftData

/// One line of the ledger: money in or money out, whatever produced it.
///
/// He reads his books the way he reads a bank statement, so purchases, grading
/// charges, and sales sit in one list in date order rather than in three
/// screens he has to reconcile by hand.
///
/// This is not a reporting layer. It aggregates nothing by vendor, set, or
/// product — see decision 23 in docs/00-brief.md, amended 2026-09-11. A month
/// header carries the month's two totals, which is the same table docs/04
/// already prints, and the Summary tab totals the whole business over time.
/// Neither one slices. A per-vendor or per-set row belongs in neither.
struct LedgerEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        case purchase(UUID)
        case grading(UUID)
        case sale(UUID)
        case expense(UUID)
    }

    var kind: Kind
    var date: Date
    var title: String
    var detail: String
    /// Positive is money in. Negative is money out.
    var amountCents: Int

    var id: Kind { kind }
    var isMoneyIn: Bool { amountCents >= 0 }

    static func entries(
        purchases: [Purchase],
        grading: [GradingSubmission],
        sales: [Sale],
        expenses: [BusinessExpense] = []
    ) -> [LedgerEntry] {
        var out: [LedgerEntry] = []
        out.reserveCapacity(purchases.count + grading.count + sales.count + expenses.count)

        for purchase in purchases {
            out.append(
                LedgerEntry(
                    kind: .purchase(purchase.id),
                    date: purchase.date,
                    title: purchase.vendor.isEmpty ? "Purchase" : purchase.vendor,
                    detail: purchase.note.isEmpty ? cardCount(purchase) : "\(cardCount(purchase)) · \(purchase.note)",
                    amountCents: -purchase.landedCostCents
                )
            )
        }

        for submission in grading {
            let count = submission.entries.count
            out.append(
                LedgerEntry(
                    kind: .grading(submission.id),
                    date: submission.shippedAt ?? submission.returnedAt ?? .distantPast,
                    title: submission.graderRaw.isEmpty ? "Grading" : "\(submission.graderRaw.uppercased()) grading",
                    detail: count == 0 ? "no cards attached" : "\(count) cards",
                    amountCents: -submission.totalCostCents
                )
            )
        }

        for sale in sales {
            let lines = sale.lines.count
            out.append(
                LedgerEntry(
                    kind: .sale(sale.id),
                    date: sale.soldAt,
                    title: sale.channelRaw.isEmpty ? "Sale" : Self.channelName(sale.channelRaw),
                    detail: lines == 0 ? "no cards recorded" : (lines == 1 ? "1 card" : "\(lines) cards"),
                    amountCents: sale.netCents
                )
            )
        }

        for expense in expenses {
            out.append(
                LedgerEntry(
                    kind: .expense(expense.id),
                    date: expense.date,
                    title: expense.vendor.isEmpty ? "Expense" : expense.vendor,
                    detail: expense.category.isEmpty ? expense.note : expense.category,
                    amountCents: -expense.amountCents
                )
            )
        }

        return out.sorted { $0.date == $1.date ? $0.title < $1.title : $0.date > $1.date }
    }

    /// How many cards came out of a purchase. "no cards yet" is the gap he
    /// looks for: money on the books with nothing in inventory to show for it.
    ///
    /// A rip of packs from several purchases hangs every pull on one of them.
    /// That purchase says its cards came from a shared rip, and the others say
    /// which purchase holds their pulls, not "no cards yet": the gap that
    /// phrase points at is not there. The amount on the row stays what he paid.
    static func cardCount(_ purchase: Purchase) -> String {
        let count = purchase.items.reduce(0) { $0 + $1.cards.count }
        let shared = sharedRipHomes(of: purchase)
        switch count {
        case 0:
            if let home = shared.first(where: { $0.id != purchase.id }) {
                return "ripped with \(home.vendor.isEmpty ? "another purchase" : home.vendor)"
            }
            return "no cards yet"
        case 1: return shared.isEmpty ? "1 card" : "1 card · shared rip"
        default: return shared.isEmpty ? "\(count) cards" : "\(count) cards · shared rip"
        }
    }

    /// The purchases that hold the pulls of each rip this purchase shares with
    /// another purchase. Empty when every rip on it was its own.
    static func sharedRipHomes(of purchase: Purchase) -> [Purchase] {
        var homes: [Purchase] = []
        var seen = Set<UUID>()
        for item in purchase.items where item.isRipped && item.ripGroupId != nil {
            let group = RipPool.lines(of: item)
            guard Set(group.compactMap { $0.purchase?.id }).count > 1,
                  let home = RipPool.home(of: group)?.purchase,
                  seen.insert(home.id).inserted
            else { continue }
            homes.append(home)
        }
        return homes
    }

    static func channelName(_ raw: String) -> String {
        switch raw {
        case "tcgplayer": return "TCGplayer"
        case "ebay": return "eBay"
        case "whatnot": return "Whatnot"
        case "local": return "Local"
        default: return raw.capitalized
        }
    }
}

/// The entries of one month, and what the month did.
struct LedgerMonth: Identifiable {
    var start: Date
    var entries: [LedgerEntry]

    var id: Date { start }
    var moneyInCents: Int { entries.filter(\.isMoneyIn).reduce(0) { $0 + $1.amountCents } }
    var moneyOutCents: Int { -entries.filter { !$0.isMoneyIn }.reduce(0) { $0 + $1.amountCents } }

    var title: String { start.formatted(.dateTime.month(.wide).year()) }

    static func group(_ entries: [LedgerEntry], calendar: Calendar = .current) -> [LedgerMonth] {
        let buckets = Dictionary(grouping: entries) { entry in
            calendar.date(from: calendar.dateComponents([.year, .month], from: entry.date)) ?? entry.date
        }
        return buckets
            .map { LedgerMonth(start: $0.key, entries: $0.value) }
            .sorted { $0.start > $1.start }
    }
}

/// The two halves of the ledger: what happened, and how it is going.
///
/// Activity is the bank statement. Summary answers the question in the brief's
/// one-sentence goal, which a list of transactions cannot answer.
enum LedgerTab: String, CaseIterable, Identifiable {
    case activity = "Activity"
    case summary = "Summary"

    var id: String { rawValue }
}

/// What the ledger shows, and what it hides.
enum LedgerFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case moneyIn = "In"
    case moneyOut = "Out"

    var id: String { rawValue }

    func keeps(_ entry: LedgerEntry) -> Bool {
        switch self {
        case .all: return true
        case .moneyIn: return entry.isMoneyIn
        case .moneyOut: return !entry.isMoneyIn
        }
    }
}

/// What he typed in the search bar, and what it keeps.
///
/// He remembers a row two ways: who it was with, and what it cost. "novatcg"
/// finds the order; "324" finds it when the vendor name has gone but the
/// amount has not. So one bar takes both, and a row survives if either half
/// matches. Two bars, or a scope picker, would make him say which kind of
/// remembering he is doing before he is allowed to search.
struct LedgerSearch {
    private let text: String
    /// The typed amount as plain digits, e.g. "324.5". Nil when what he typed
    /// is not a number, which is most of the time.
    private let amount: String?

    var isEmpty: Bool { text.isEmpty }

    init(_ raw: String) {
        text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // "$1,250" and "1250" are the same search. Nothing else is stripped:
        // a stray letter means he is typing a name, not an amount.
        let bare = text.replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        let digits = bare.filter(\.isNumber)
        let dots = bare.filter { $0 == "." }
        amount = !digits.isEmpty && dots.count <= 1 && digits.count + dots.count == bare.count
            ? bare
            : nil
    }

    func keeps(_ entry: LedgerEntry) -> Bool {
        if isEmpty { return true }
        if matchesText(entry) { return true }
        return matchesAmount(entry)
    }

    private func matchesText(_ entry: LedgerEntry) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return entry.title.range(of: text, options: options) != nil
            || entry.detail.range(of: text, options: options) != nil
    }

    /// A typed amount matches from the front, never from the middle. "324"
    /// finds $324.50 and $3,240.00; it does not drag in the $17.32 and the
    /// $4.32 that a substring match would, and those are the rows that make a
    /// search useless on 300 entries.
    private func matchesAmount(_ entry: LedgerEntry) -> Bool {
        guard let amount else { return false }
        return LedgerExport.dollars(abs(entry.amountCents)).hasPrefix(amount)
    }
}
