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
                    detail: purchase.note,
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
