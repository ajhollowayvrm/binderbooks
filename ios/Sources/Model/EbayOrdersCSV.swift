import Foundation

/// eBay's All Orders Report, read into orders.
///
/// The report is not a clean table. Verified on AJ's export of 2026-09-20:
///
/// - The first line is a row of bare commas and the header is the second line,
///   so the header is found by looking for it rather than taken from the top.
/// - A padding row of empty quoted fields follows the header, and the file
///   ends with "45,record(s) downloaded," and "Seller ID : ibuytoomanycards".
///   None of the three is a row not read: a row with no date, no title and no
///   price is the report's own furniture.
/// - A multi-item order is a summary row, blank in "Item Number" and "Item
///   Title", carrying the order's money, followed by one row per item. Sales
///   record 119 sold for $28.00, which is its two items at $13.00 and $15.00.
///   A single-item order is one row that is both.
/// - Two rows carry no "Order Number". Their "Sales Record Number" is the
///   order id instead, so the sale is read rather than dropped. eBay gives
///   each order one record number, so two such rows are two orders. The cost
///   of the fallback: if eBay later gives one of them a real order number, a
///   re-import sees an order his books do not have and creates it a second
///   time, because the sale already carries "145" and cannot be matched.
/// - There is no Status column, so no order here is ever canceled.
/// - There is no Condition column either. The grade is in the listing title,
///   "… CGC Pristine 10", and that is where `SoldCondition` gets it from.
///
/// "Sold For" and "Shipping And Handling" are the money, not "Total Price",
/// which adds the tax that `SalesOrderImport.ebayAllowanceCents` already
/// allows for. Buyer names and addresses are never read.
enum EbayOrdersCSV {
    static let requiredColumns = ["Sales Record Number", "Order Number", "Item Title", "Sold For", "Sale Date"]

    /// "eBay orders", the label on a row this file could not read.
    static let fileLabel = "eBay orders"

    static func read(_ text: String) throws -> SalesOrderCSV.Contents {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        let table = SalesOrderCSV.rows(body)
        guard let start = headerIndex(table) else {
            throw SalesOrderCSV.ReadError.missingColumns(requiredColumns)
        }
        let header = table[start].map { $0.trimmingCharacters(in: .whitespaces) }
        let column = Dictionary(header.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })

        var orders: [SalesOrderCSV.Order] = []
        var position: [String: Int] = [:]
        /// The rows of each order, so its money can be read once it is known
        /// whether a summary row came with them.
        var rowsOf: [String: [(soldCents: Int, shippingCents: Int, isSummary: Bool)]] = [:]
        var unreadable: [SalesOrderCSV.UnreadableRow] = []

        for (offset, row) in table[(start + 1)...].enumerated() {
            func value(_ name: String) -> String {
                guard let index = column[name], index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespaces)
            }

            let title = value("Item Title")
            let date = value("Sale Date")
            let sold = value("Sold For")
            // The padding row and the two footer lines.
            if title.isEmpty, date.isEmpty, sold.isEmpty { continue }

            let record = value("Sales Record Number")
            let number = value("Order Number")
            let orderId = number.isEmpty ? record : number
            guard !orderId.isEmpty,
                  let soldAt = SalesOrderCSV.day(date),
                  let soldCents = Money.cents(from: sold)
            else {
                unreadable.append(SalesOrderCSV.UnreadableRow(file: fileLabel, line: offset + start + 2))
                continue
            }

            // The order number is the order: record 119's three rows all
            // carry it. Grouping on the record number instead would let two
            // records that share an order number become two orders with one
            // number, which everything downstream keys on.
            let key = orderId
            if position[key] == nil {
                position[key] = orders.count
                orders.append(SalesOrderCSV.Order(
                    channel: .ebay, orderId: orderId, soldAt: soldAt, status: "",
                    productCents: 0, shippingChargedCents: 0, lines: []
                ))
            }
            rowsOf[key, default: []].append((
                soldCents: soldCents,
                shippingCents: Money.cents(from: value("Shipping And Handling")) ?? 0,
                isSummary: title.isEmpty
            ))
            guard !title.isEmpty, let index = position[key] else { continue }
            orders[index].lines.append(SalesOrderCSV.Line(
                productLine: "Pokemon", setName: "", number: "",
                productName: title, condition: grade(inTitle: title),
                skuId: nil, quantity: max(1, Int(value("Quantity")) ?? 1)
            ))
        }

        // The summary row is the order's money. Without one, the rows are the
        // items themselves and their prices add up to the order — which for a
        // one-row order is that row.
        for (key, index) in position {
            let rows = rowsOf[key] ?? []
            let money = rows.first { $0.isSummary }.map { [$0] } ?? rows
            orders[index].productCents = money.reduce(0) { $0 + $1.soldCents }
            orders[index].shippingChargedCents = money.reduce(0) { $0 + $1.shippingCents }
        }
        return SalesOrderCSV.Contents(orders: orders, unreadableRows: unreadable.sorted { $0.line < $1.line })
    }

    /// The first row that holds every required column. The report opens with a
    /// row of bare commas, so the header is not the first row.
    static func headerIndex(_ table: [[String]]) -> Int? {
        table.firstIndex { row in
            let names = Set(row.map { $0.trimmingCharacters(in: .whitespaces) })
            return requiredColumns.allSatisfy(names.contains)
        }
    }

    /// The grade a listing title carries: "CGC Pristine 10", "PSA 9", or "" for
    /// a title with no grader in it. `SoldCondition.parse` reads what comes
    /// back, so a raw card and a slab still land on the right copy.
    ///
    /// The grader word anchors it, because a title is full of other numbers:
    /// "2024 Pokemon Pikachu ex 122/106 … CGC Pristine 10" must give 10, not
    /// 2024 or 122. So at most two words of a grade name may sit between the
    /// grader and its number, and the number may not be part of "107/098".
    /// "Tag Team" is a card, not the grader TAG.
    static func grade(inTitle title: String) -> String {
        guard let match = title.firstMatch(of: gradePattern) else { return "" }
        let words = String(match.2).trimmingCharacters(in: .whitespaces)
        return [String(match.1), words, String(match.3)].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static let gradePattern =
        #/(?i)\b(PSA|CGC|BGS|SGC|TAG)\b(?!\s+Team\b)[\s:]*((?:(?![0-9])\S+\s+){0,2}?)(\d{1,2}(?:\.\d)?)(?![\d./])/#
}
