import Foundation

/// The ledger's Activity as a CSV: money in and money out, one row per entry,
/// newest first, the way the Activity list reads.
///
/// Only the books, not the collection. The collection export carries the
/// cards; this file carries the money, for a spreadsheet. In and Out are two
/// columns of plain dollars, "193.39" with no sign and no "$", so a sheet can
/// total each side with no cleanup.
enum LedgerExport {
    static let columns = ["Date", "Type", "Name", "Detail", "In", "Out"]

    static func csv(_ entries: [LedgerEntry]) -> String {
        var lines = [columns.joined(separator: ",")]
        for entry in entries {
            let amount = dollars(abs(entry.amountCents))
            lines.append([
                // A grading charge with no ship or return date sorts last in
                // the app. Its date cell stays empty, not "0001-01-01".
                entry.date == .distantPast ? "" : day.string(from: entry.date),
                type(entry.kind),
                entry.title,
                entry.detail,
                entry.isMoneyIn ? amount : "",
                entry.isMoneyIn ? "" : amount,
            ].map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func suggestedFileName(now: Date = Date()) -> String {
        "ledger-\(day.string(from: now)).csv"
    }

    static func type(_ kind: LedgerEntry.Kind) -> String {
        switch kind {
        case .purchase: return "Purchase"
        case .grading: return "Grading"
        case .sale: return "Sale"
        case .expense: return "Expense"
        }
    }

    /// Int cents to "1234.05". No `Double`, so no cent is lost.
    static func dollars(_ cents: Int) -> String {
        let remainder = cents % 100
        return "\(cents / 100)." + (remainder < 10 ? "0\(remainder)" : "\(remainder)")
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
