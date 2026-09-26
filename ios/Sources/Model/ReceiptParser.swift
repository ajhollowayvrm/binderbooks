import CoreGraphics
import Foundation

/// What a receipt says: the day, who was paid, and the money.
///
/// Every field is a guess from text the app read. A field it did not find is
/// nil, and the sheet leaves that field for him to type.
struct ReceiptDraft: Equatable {
    var date: Date?
    var vendor: String?
    /// What left his account. The fact the entry must match.
    var totalCents: Int?
    var subtotalCents: Int?
    var taxCents: Int?
    var shippingCents: Int?
    /// A grader's invoice. The sheet records it as a grading charge.
    var looksLikeGrading = false

    /// The purchase fields that make the landed cost equal the total. Without a
    /// total, the subtotal is the item cost. Nil when neither was found.
    var purchaseFields: (itemCents: Int, shippingCents: Int, taxCents: Int)? {
        let shipping = shippingCents ?? 0
        let tax = taxCents ?? 0
        if let totalCents {
            let item = totalCents - shipping - tax
            // A tax or shipping line read wrong can be larger than the total.
            // The total is still the fact, so it goes on the item cost alone.
            return item >= 0 ? (item, shipping, tax) : (totalCents, 0, 0)
        }
        if let subtotalCents { return (subtotalCents, shipping, tax) }
        return nil
    }

    /// The grading fields: the grader's fees and the box to the grader.
    var gradingFields: (feesCents: Int, shippingCents: Int)? {
        guard let total = totalCents ?? subtotalCents else { return nil }
        let shipping = shippingCents ?? 0
        return total - shipping >= 0 ? (total - shipping, shipping) : (total, 0)
    }

    /// The expense amount: the total, or the parts added up.
    var expenseCents: Int? {
        if let totalCents { return totalCents }
        guard let subtotalCents else { return nil }
        return subtotalCents + (taxCents ?? 0) + (shippingCents ?? 0)
    }
}

/// Reads a `ReceiptDraft` out of the lines of a receipt.
///
/// The input is text, one line per row of the receipt, top to bottom. A row
/// holds its label and its amount together: "Order Total: $42.17". See
/// `rows(_:)` for how a photo becomes rows.
enum ReceiptParser {
    /// The stores he buys from, spelled the way the ledger spells them. The
    /// vendors already on the ledger are added to these at run time.
    static let builtInVendors = [
        "Amazon", "Walmart", "Target", "Costco", "Sam's Club", "Best Buy", "GameStop",
        "Barnes & Noble", "Dollar Tree", "Five Below", "Walgreens", "CVS", "Meijer",
        "TCGplayer", "eBay", "Whatnot", "Pokémon Center", "Mercari", "Facebook",
        "PSA", "CGC", "Beckett", "TAG", "SGC",
        "USPS", "UPS", "FedEx", "Pirate Ship", "Staples", "Ultra PRO",
    ]

    static let graders = ["PSA", "CGC", "Beckett", "BGS", "TAG", "SGC"]

    static func parse(_ lines: [String], knownVendors: [String] = [], now: Date = Date()) -> ReceiptDraft {
        let lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var draft = ReceiptDraft()
        draft.totalCents = total(lines)
        draft.subtotalCents = labelled(lines, matches: isSubtotal)
        draft.taxCents = tax(lines)
        draft.shippingCents = shipping(lines)
        draft.date = date(lines, now: now)
        draft.vendor = vendor(lines, known: knownVendors)

        let text = lines.joined(separator: "\n").lowercased()
        draft.looksLikeGrading = draft.vendor.map { v in graders.contains { $0.caseInsensitiveCompare(v) == .orderedSame } } ?? false
            || text.contains("grading submission")
        return draft
    }

    // MARK: - Money

    /// `NSRegularExpression`, not `Regex`: Swift's `Regex` has no lookbehind,
    /// and a `try!` on it traps on first use.
    private static let moneyPattern = try! NSRegularExpression(pattern: #"(?<![\d.,])-?\$?\s?(\d{1,3}(?:,\d{3})+|\d+)\.(\d{2})(?!\d)"#)
    private static let onlyMoneyPattern = try! Regex(#"^[A-Z]{0,3}\s?-?\$?\s?(\d{1,3}(?:,\d{3})+|\d+)\.\d{2}\s?[A-Z]{0,3}$"#)

    /// Every amount on the line, in cents, left to right.
    static func amounts(in line: String) -> [Int] {
        moneyPattern.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
            guard let range = Range(match.range, in: line) else { return nil }
            let found = String(line[range])
            guard let cents = Int(found.filter(\.isNumber)) else { return nil }
            return found.contains("-") ? -cents : cents
        }
    }

    /// The amount a labelled row carries: the rightmost amount on the row. A
    /// screenshot can put the amount on the next row alone, so a row with no
    /// amount takes the next row when that row is only an amount.
    private static func amount(at index: Int, in lines: [String]) -> Int? {
        if let last = amounts(in: lines[index]).last { return abs(last) }
        let next = index + 1
        guard next < lines.count, lines[next].wholeMatch(of: onlyMoneyPattern) != nil else { return nil }
        return amounts(in: lines[next]).last.map(abs)
    }

    private static func labelled(_ lines: [String], matches: (String) -> Bool) -> Int? {
        for (index, line) in lines.enumerated() where matches(line.lowercased()) {
            if let cents = amount(at: index, in: lines) { return cents }
        }
        return nil
    }

    private static func isSubtotal(_ lower: String) -> Bool {
        ["subtotal", "sub total", "sub-total", "merchandise total"].contains { lower.contains($0) }
    }

    /// The total. A named total, "Grand Total" or "Order Total", beats a plain
    /// "Total". Of two totals with the same rank, the larger one wins, because
    /// a page can repeat the total and a smaller "total" is part of it.
    private static func total(_ lines: [String]) -> Int? {
        let named = ["grand total", "order total", "total charged", "amount charged", "total paid",
                     "amount paid", "payment total", "total amount", "you paid", "charged to"]
        let excluded = ["subtotal", "sub total", "sub-total", "total savings", "you saved", "total items",
                        "total qty", "total quantity", "before tax", "total tax", "tax total", "merchandise total"]
        var best: (rank: Int, cents: Int)?
        for (index, line) in lines.enumerated() {
            let lower = line.lowercased()
            guard !excluded.contains(where: { lower.contains($0) }) else { continue }
            let rank: Int
            if named.contains(where: { lower.contains($0) }) {
                rank = 2
            } else if lower.range(of: #"\btotal\b"#, options: .regularExpression) != nil {
                rank = 1
            } else {
                continue
            }
            guard let cents = amount(at: index, in: lines) else { continue }
            if best == nil || rank > best!.rank || (rank == best!.rank && cents > best!.cents) {
                best = (rank, cents)
            }
        }
        return best?.cents
    }

    /// The tax. A "Total tax" row wins. Otherwise the tax rows add up, because
    /// a store can list a state tax and a city tax.
    private static func tax(_ lines: [String]) -> Int? {
        let excluded = ["before tax", "pre-tax", "pretax", "tax id", "tax exempt", "excl. tax", "tax-free"]
        var rows: [(lower: String, cents: Int)] = []
        for (index, line) in lines.enumerated() {
            let lower = line.lowercased()
            guard lower.range(of: #"\btax\b"#, options: .regularExpression) != nil,
                  !excluded.contains(where: { lower.contains($0) }),
                  let cents = amount(at: index, in: lines)
            else { continue }
            rows.append((lower, cents))
        }
        if let summed = rows.first(where: { $0.lower.contains("total") }) { return summed.cents }
        return rows.isEmpty ? nil : rows.reduce(0) { $0 + $1.cents }
    }

    /// The shipping. "Free" is $0.
    private static func shipping(_ lines: [String]) -> Int? {
        let words = ["shipping", "delivery", "postage", "s&h", "handling"]
        let excluded = ["address", "ship to", "shipping to", "delivery date", "estimated delivery", "delivered", "free shipping on"]
        for (index, line) in lines.enumerated() {
            let lower = line.lowercased()
            guard words.contains(where: { lower.contains($0) }),
                  !excluded.contains(where: { lower.contains($0) })
            else { continue }
            if let cents = amount(at: index, in: lines) { return cents }
            if lower.contains("free") { return 0 }
        }
        return nil
    }

    // MARK: - Date

    private static let dateShape = try! Regex(#"\d{1,4}[/.-]\d{1,2}([/.-]\d{2,4})?|(?i:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}"#)

    /// The first date on the receipt that is not in the future and not more
    /// than two years old. A time alone, "14:33", is not a date.
    private static func date(_ lines: [String], now: Date) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let earliest = now.addingTimeInterval(-2 * 365 * 86_400)
        let latest = now.addingTimeInterval(86_400)
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            for match in detector.matches(in: line, range: range) {
                guard let date = match.date,
                      let swiftRange = Range(match.range, in: line),
                      line[swiftRange].contains(dateShape),
                      date >= earliest, date <= latest
                else { continue }
                return date
            }
        }
        return nil
    }

    // MARK: - Vendor

    /// The first store name the receipt mentions, from the built-in list and
    /// the ledger's own vendors. A short name in capitals, "UPS" or "TAG",
    /// must match in capitals, or "tag" in "price tag" is a grader.
    /// Otherwise the first line of the receipt that reads as a name.
    private static func vendor(_ lines: [String], known: [String]) -> String? {
        var names = builtInVendors
        for name in known where name.count >= 3 && !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            names.append(name)
        }
        // A longer name first, so "Pokémon Center" wins over a vendor "Pokémon".
        names.sort { $0.count > $1.count }

        for line in lines {
            for name in names {
                let caseSensitive = name.count <= 4 && name == name.uppercased()
                let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
                let pattern = #"(?<![A-Za-z])"# + NSRegularExpression.escapedPattern(for: name) + #"(?![A-Za-z])"#
                if line.range(of: pattern, options: options.union(.regularExpression)) != nil {
                    return name
                }
            }
        }

        let skip = ["receipt", "invoice", "order", "thank", "welcome", "summary", "details"]
        for line in lines.prefix(3) {
            let letters = line.filter(\.isLetter).count
            let lower = line.lowercased()
            if letters >= 3, letters * 2 >= line.count, line.count <= 40,
               !skip.contains(where: { lower.contains($0) }) {
                return line
            }
        }
        return nil
    }

    // MARK: - Rows

    /// One piece of text Vision read, in the image's top-down fractions.
    struct TextBox: Equatable {
        var text: String
        var minX: CGFloat
        /// 0 at the top of the image, 1 at the bottom.
        var midY: CGFloat
        var height: CGFloat
    }

    /// The boxes joined into rows, top to bottom, each row left to right.
    ///
    /// Vision reads "Total" and "$42.17" as two boxes when a gap separates
    /// them. The parser needs them on one line, so two boxes whose middles
    /// sit within half a box height of each other are one row.
    static func rows(_ boxes: [TextBox]) -> [String] {
        var rows: [[TextBox]] = []
        for box in boxes.sorted(by: { $0.midY < $1.midY }) {
            if let last = rows.last, let anchor = last.first,
               abs(box.midY - anchor.midY) < max(anchor.height, box.height) / 2 {
                rows[rows.count - 1].append(box)
            } else {
                rows.append([box])
            }
        }
        return rows.map { row in row.sorted { $0.minX < $1.minX }.map(\.text).joined(separator: " ") }
    }
}
