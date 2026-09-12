import Foundation

/// A marketplace's sold-orders CSV, read into orders.
///
/// TCGplayer's "Sold Items" export and the same file with eBay rows added have
/// the same columns; the second adds "Marketplace" and "eBay Item ID". One row
/// is one line of an order. The money columns belong to the order and repeat on
/// every line: an 18-card order that sold for $10.68 says 10.68 eighteen times.
/// So the money is read once for each order and never summed over lines.
///
/// "Buyer Name" is never read. The store does not keep who bought a card.
enum SalesOrderCSV {
    enum Channel: String, Sendable {
        case tcgplayer
        case ebay
    }

    struct Line: Equatable, Sendable {
        /// "Pokemon", "Pokemon Japan": the catalog's category name. eBay rows
        /// say "Pokemon" for Japanese cards too.
        var productLine: String
        /// TCGplayer's set name, which is the catalog's. Empty on eBay.
        var setName: String
        var number: String
        /// TCGplayer's product name, or the eBay listing title.
        var productName: String
        /// "Near Mint Holofoil - Japanese", or on eBay "CGC Pristine 10".
        var condition: String
        var skuId: Int?
        var quantity: Int
    }

    struct Order: Equatable, Sendable, Identifiable {
        var channel: Channel
        var orderId: String
        /// Noon UTC on the order's day, the way the seed import dates a row.
        var soldAt: Date
        var status: String
        var productCents: Int
        /// What the buyer paid for shipping. Blank on most eBay rows.
        var shippingChargedCents: Int
        var lines: [Line]

        var id: String { orderId }
        var isCanceled: Bool { status.lowercased().contains("cancel") }
        var cardCount: Int { lines.reduce(0) { $0 + $1.quantity } }
        var totalCents: Int { productCents + shippingChargedCents }
    }

    struct Contents: Equatable, Sendable {
        var orders: [Order]
        /// Line numbers in the file, with the header as line 1.
        var unreadableRows: [Int]
    }

    enum ReadError: LocalizedError, Equatable {
        case missingColumns([String])

        var errorDescription: String? {
            switch self {
            case .missingColumns(let names):
                return "This is not a sold-orders file. It has no \(names.joined(separator: ", ")) column."
            }
        }
    }

    static let requiredColumns = ["Order #", "Order Date", "Status", "Product Name", "Product Amt"]

    static func read(_ text: String) throws -> Contents {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        let table = rows(body)
        let header = (table.first ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
        let column = Dictionary(header.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let missing = requiredColumns.filter { column[$0] == nil }
        guard missing.isEmpty else { throw ReadError.missingColumns(missing) }

        var orders: [Order] = []
        var position: [String: Int] = [:]
        var unreadable: [Int] = []

        for (offset, row) in table.dropFirst().enumerated() {
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            func value(_ name: String) -> String {
                guard let index = column[name], index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespaces)
            }

            let orderId = value("Order #")
            guard !orderId.isEmpty,
                  let channel = channel(value("Marketplace")),
                  let soldAt = day(value("Order Date")),
                  let productCents = Money.cents(from: value("Product Amt"))
            else {
                unreadable.append(offset + 2)
                continue
            }

            let line = Line(
                productLine: value("Product Line"), setName: value("Set"), number: value("Number"),
                productName: value("Product Name"), condition: value("Condition"),
                skuId: Int(value("SkuId")), quantity: max(1, Int(value("Qty")) ?? 1)
            )
            let key = channel.rawValue + " " + orderId
            if let index = position[key] {
                orders[index].lines.append(line)
            } else {
                position[key] = orders.count
                orders.append(Order(
                    channel: channel, orderId: orderId, soldAt: soldAt, status: value("Status"),
                    productCents: productCents, shippingChargedCents: Money.cents(from: value("Shipping Amt")) ?? 0,
                    lines: [line]
                ))
            }
        }
        return Contents(orders: orders, unreadableRows: unreadable)
    }

    /// A file with no "Marketplace" column is TCGplayer's own export.
    static func channel(_ text: String) -> Channel? {
        switch text.lowercased() {
        case "", "tcgplayer": return .tcgplayer
        case "ebay": return .ebay
        default: return nil
        }
    }

    /// TCGplayer's export writes "Friday, 03 July 2026". The combined file
    /// writes "2026-07-03".
    static func day(_ text: String) -> Date? {
        for formatter in dayFormatters {
            if let date = formatter.date(from: text) { return date.addingTimeInterval(12 * 60 * 60) }
        }
        return nil
    }

    private static let dayFormatters: [DateFormatter] = ["yyyy-MM-dd", "EEEE, dd MMMM yyyy", "M/d/yyyy"].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }

    /// RFC 4180 fields: quotes around a field that holds a comma, a doubled
    /// quote for a quote. A spreadsheet writes CRLF, which Swift reads as one
    /// `Character`.
    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" {
                quoted = true
            } else if character == "," {
                row.append(field)
                field = ""
            } else if character == "\n" || character == "\r\n" || character == "\r" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(character)
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
