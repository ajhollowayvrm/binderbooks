import Foundation
import SwiftData

/// An order that sold, however it was exported.
///
/// This is the shape every reader produces and the import plans against:
/// `TCGplayerOrderExports` joins TCGplayer's order list and pull sheet into it,
/// and `EbayOrdersCSV` reads eBay's All Orders Report into it. It also holds
/// what they share — the CSV tokenizer, the date formats, and the row that
/// would not read.
///
/// TCGplayer's "Sold Items" CSV was read here too until 2026-09-20. He cannot
/// export it himself, and the order list and pull sheet give the same orders,
/// so it is gone.
///
/// A buyer's name, address and email are never read. The store does not keep
/// who bought a card.
enum SalesOrderCSV {
    /// Which marketplace the order came from.
    enum Channel: String, Sendable {
        case tcgplayer
        case ebay
    }

    struct Line: Equatable, Sendable {
        /// "Pokemon", "Pokemon Japan": the catalog's category name. An eBay
        /// row says "Pokemon" for a Japanese card too.
        var productLine: String
        /// TCGplayer's set name, which is the catalog's. Empty on eBay.
        var setName: String
        var number: String
        /// TCGplayer's product name, or eBay's listing title.
        var productName: String
        /// "Near Mint Holofoil - Japanese", or on eBay the grade its listing
        /// title carried, "CGC Pristine 10".
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
        /// What the buyer paid for shipping.
        var shippingChargedCents: Int
        var lines: [Line]

        var id: String { orderId }
        var isCanceled: Bool { status.lowercased().contains("cancel") }
        var cardCount: Int { lines.reduce(0) { $0 + $1.quantity } }
        var totalCents: Int { productCents + shippingChargedCents }
    }

    /// A row that would not read, and which file it was in. Several files can
    /// be imported together, so a bare line number would not say where to look.
    struct UnreadableRow: Equatable, Sendable {
        /// The kind of file, not its name: "Order list", "eBay orders".
        var file: String
        /// The line in that file, with its header as line 1.
        var line: Int

        var label: String { "\(file) line \(line)" }
    }

    struct Contents: Equatable, Sendable {
        var orders: [Order]
        var unreadableRows: [UnreadableRow]
    }

    enum ReadError: LocalizedError, Equatable {
        case missingColumns([String])

        var errorDescription: String? {
            switch self {
            case .missingColumns(let names):
                return "This file has no \(names.joined(separator: ", ")) column."
            }
        }
    }

    /// The labels an unreadable row carries, one per kind of file.
    static let orderListLabel = "Order list"
    static let pullSheetLabel = "Pull sheet"

    /// TCGplayer's order list writes "Friday, 03 July 2026", and eBay's report
    /// "Sep-18-26", or "Sep-18-26 14:32:11" when the seller asked it for times.
    /// A two-digit year lands in Foundation's moving window, which reads 26 as
    /// 2026 for decades yet.
    static func day(_ text: String) -> Date? {
        for formatter in dayFormatters {
            // "M/d/yyyy" reads eBay's "Sep-18-26" as the year 26 and wins
            // before "MMM-dd-yy" has a turn. No order he imports is that old,
            // so a year before 2000 means the wrong format.
            guard let date = formatter.date(from: text), utc.component(.year, from: date) >= 2000 else { continue }
            return date.addingTimeInterval(12 * 60 * 60)
        }
        return nil
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Moves a sale that `day` filed in the year 26 to 2026. The eBay import
    /// did that to every order from 2026-09-12 to 2026-09-22. A second run
    /// finds nothing, so it runs at every launch.
    @MainActor
    static func repairCenturyDates(_ context: ModelContext) {
        let cutoff = utc.date(from: DateComponents(year: 1000, month: 1, day: 1))!
        let descriptor = FetchDescriptor<Sale>(predicate: #Predicate { $0.soldAt < cutoff })
        guard let sales = try? context.fetch(descriptor), !sales.isEmpty else { return }
        for sale in sales {
            if let fixed = utc.date(byAdding: .year, value: 2000, to: sale.soldAt) { sale.soldAt = fixed }
        }
        try? context.save()
    }

    private static let dayFormatters: [DateFormatter] = ["yyyy-MM-dd", "EEEE, dd MMMM yyyy", "M/d/yyyy", "MMM-dd-yy", "MMM-dd-yy HH:mm:ss"].map { format in
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

/// TCGplayer's Orders page exports two files, and neither one is an order with
/// its cards. The order list has one row per order: the status and the money.
/// The pull sheet has one row per SKU, and "Order Quantity" names each order
/// that holds it: "62955D06-A:1 | 62955D06-B:2". Joined, they are the orders
/// the sold-orders import reads.
///
/// Verified on AJ's exports of 2026-09-15:
///
/// - The pull sheet ends with a row that lists its orders, "Orders Contained
///   in Pull Sheet:". It is not a card.
/// - "Quantity" can be less than the orders it names add up to, so each
///   order's own count in "Order Quantity" is the line's quantity.
/// - The pull sheet held 100 of 149 orders. An order that is not in the pull
///   sheet comes through with no cards.
/// - "Buyer Name" is never read.
enum TCGplayerOrderExports {
    enum Kind: Equatable {
        case orderList
        case pullSheet
    }

    enum JoinError: LocalizedError, Equatable {
        case notTheTwoFiles

        var errorDescription: String? {
            "Pick TCGplayer's order list and its pull sheet together: Orders, then Export Orders and Export Pull Sheet."
        }
    }

    struct Joined: Equatable, Sendable {
        var contents: SalesOrderCSV.Contents
        /// Orders in the list that are not canceled and have no card in the
        /// pull sheet. Every one of them, when no pull sheet was picked.
        var ordersWithoutCards: [String]
        /// Orders the pull sheet names that the order list does not hold. Their
        /// cards are not read.
        var unknownOrders: [String]
    }

    static let orderListColumns = ["Order #", "Order Date", "Status", "Product Amt", "Shipping Amt"]
    static let pullSheetColumns = ["Product Line", "Product Name", "Condition", "Number", "Set", "SkuId", "Order Quantity"]

    /// The pull sheet is the one with a product line and an order quantity.
    static func kind(of text: String) -> Kind? {
        let header = Set(columns(table(text)).keys)
        if pullSheetColumns.allSatisfy(header.contains) { return .pullSheet }
        if orderListColumns.allSatisfy(header.contains), !header.contains("Product Line") { return .orderList }
        return nil
    }

    /// The pull sheet is optional: an order list on its own gives the orders
    /// and their money, with no cards on any of them.
    static func join(orderList: String, pullSheet: String?) throws -> Joined {
        guard kind(of: orderList) == .orderList else { throw JoinError.notTheTwoFiles }
        if let pullSheet, kind(of: pullSheet) != .pullSheet { throw JoinError.notTheTwoFiles }

        var linesByOrder: [String: [SalesOrderCSV.Line]] = [:]
        var unreadableRows: [SalesOrderCSV.UnreadableRow] = []
        let sheet = pullSheet.map { table($0) } ?? []
        let sheetColumn = columns(sheet)
        for (offset, row) in sheet.dropFirst().enumerated() {
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            func value(_ name: String) -> String { cell(row, sheetColumn[name]) }
            if value("Product Line").hasPrefix("Orders Contained") { continue }
            let entries = orderQuantities(value("Order Quantity"))
            guard !entries.isEmpty else {
                unreadableRows.append(SalesOrderCSV.UnreadableRow(file: SalesOrderCSV.pullSheetLabel, line: offset + 2))
                continue
            }
            for (orderId, quantity) in entries {
                linesByOrder[orderId, default: []].append(SalesOrderCSV.Line(
                    productLine: value("Product Line"), setName: value("Set"), number: value("Number"),
                    productName: productName(value("Product Name")), condition: value("Condition"),
                    skuId: Int(value("SkuId")), quantity: quantity
                ))
            }
        }

        var orders: [SalesOrderCSV.Order] = []
        var known: Set<String> = []
        var withoutCards: [String] = []
        let list = table(orderList)
        let listColumn = columns(list)
        for (offset, row) in list.dropFirst().enumerated() {
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            func value(_ name: String) -> String { cell(row, listColumn[name]) }
            let orderId = value("Order #")
            guard !orderId.isEmpty,
                  let soldAt = SalesOrderCSV.day(value("Order Date")),
                  let productCents = Money.cents(from: value("Product Amt"))
            else {
                unreadableRows.append(SalesOrderCSV.UnreadableRow(file: SalesOrderCSV.orderListLabel, line: offset + 2))
                continue
            }
            guard known.insert(orderId).inserted else { continue }
            let order = SalesOrderCSV.Order(
                channel: .tcgplayer, orderId: orderId, soldAt: soldAt, status: value("Status"),
                productCents: productCents, shippingChargedCents: Money.cents(from: value("Shipping Amt")) ?? 0,
                lines: linesByOrder[orderId] ?? []
            )
            if order.lines.isEmpty, !order.isCanceled { withoutCards.append(orderId) }
            orders.append(order)
        }

        return Joined(
            contents: SalesOrderCSV.Contents(orders: orders, unreadableRows: unreadableRows),
            ordersWithoutCards: withoutCards,
            unknownOrders: linesByOrder.keys.filter { !known.contains($0) }.sorted()
        )
    }

    /// "62955D06-A:1 | 62955D06-B:2" as its orders and counts. Empty when any
    /// entry does not read, so a bad row is reported and not half read.
    static func orderQuantities(_ text: String) -> [(orderId: String, quantity: Int)] {
        var out: [(orderId: String, quantity: Int)] = []
        for part in text.split(separator: "|") {
            let entry = part.trimmingCharacters(in: .whitespaces)
            guard let colon = entry.lastIndex(of: ":"),
                  let quantity = Int(entry[entry.index(after: colon)...].trimmingCharacters(in: .whitespaces)),
                  quantity > 0
            else { return [] }
            let orderId = entry[..<colon].trimmingCharacters(in: .whitespaces)
            guard !orderId.isEmpty else { return [] }
            out.append((orderId, quantity))
        }
        return out
    }

    /// The product's own name. A custom listing puts its title after the name:
    /// "Team Rocket's Wobbuffet: Team Rocket's Wobbuffet #203 SV Promo Destined
    /// Rivals". The title starts with the card's name again, so only then is
    /// the part before ": " kept. A name with a colon of its own stays whole.
    static func productName(_ text: String) -> String {
        guard let colon = text.range(of: ": ") else { return text }
        let name = String(text[..<colon.lowerBound])
        let base = name.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? name
        guard !base.isEmpty, text[colon.upperBound...].hasPrefix(base) else { return text }
        return name
    }

    private static func table(_ text: String) -> [[String]] {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        return SalesOrderCSV.rows(body)
    }

    private static func columns(_ table: [[String]]) -> [String: Int] {
        let header = (table.first ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
        return Dictionary(header.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func cell(_ row: [String], _ index: Int?) -> String {
        guard let index, index < row.count else { return "" }
        return row[index].trimmingCharacters(in: .whitespaces)
    }
}
