import Foundation

/// The files the sold-orders import will take, in any number and combination.
///
/// He exports his month's selling as three files, and any one of them on its
/// own is a real thing to import:
///
/// - **TCGplayer's order list**, one row per order: the money and the status.
/// - **TCGplayer's pull sheet**, one row per SKU, naming the orders that hold
///   it. It carries no money, no date and no status, so it is refused on its
///   own and read beside the order list.
/// - **eBay's All Orders Report**.
///
/// TCGplayer's "Sold Items" CSV was a fourth shape until 2026-09-20. He cannot
/// export it himself, and mixed in with these it quietly lost its cards, so it
/// is gone.
enum SalesOrderSources {
    enum Kind: Equatable {
        case orderList
        case pullSheet
        case ebayOrders

        var label: String {
            switch self {
            case .orderList: return SalesOrderCSV.orderListLabel
            case .pullSheet: return SalesOrderCSV.pullSheetLabel
            case .ebayOrders: return EbayOrdersCSV.fileLabel
            }
        }
    }

    enum PickError: LocalizedError, Equatable {
        case nothingPicked
        case unrecognized
        case pickedTwice(String)
        case pullSheetAlone

        var errorDescription: String? {
            switch self {
            case .nothingPicked:
                return "No file was picked."
            case .unrecognized:
                return "One of these files is not an orders export. Pick TCGplayer's order list or pull sheet, from Orders, or eBay's All Orders Report."
            case .pickedTwice(let label):
                return "Two of these files are the same export (\(label)). Pick each one once."
            case .pullSheetAlone:
                return "A pull sheet has no money, dates or statuses. Pick TCGplayer's order list with it."
            }
        }
    }

    struct Result: Equatable {
        var contents: SalesOrderCSV.Contents
        /// The kinds of file that were read, in the order above.
        var kinds: [Kind] = []
        /// Orders with no card listed. Every order in the list, when no pull
        /// sheet came with it.
        var ordersWithoutCards: [String] = []
        /// Orders the pull sheet names that the order list does not hold.
        var unknownOrders: [String] = []
    }

    /// What kind of export this file is, or nil when it is none of them.
    ///
    /// eBay first, because it is the only one whose header is not the first
    /// row: it is found by looking for it rather than taken from the top.
    static func kind(of text: String) -> Kind? {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        if EbayOrdersCSV.headerIndex(SalesOrderCSV.rows(body)) != nil { return .ebayOrders }
        guard let tcgplayer = TCGplayerOrderExports.kind(of: text) else { return nil }
        return tcgplayer == .pullSheet ? .pullSheet : .orderList
    }

    /// Reads everything he picked into the one set of orders the import plans
    /// against.
    ///
    /// Several eBay reports are allowed: the All Orders Report reaches about
    /// three months back, so a year is four files. The rest name one export
    /// each, and two of the same one is a mistake worth saying out loud.
    static func read(_ texts: [String]) throws -> Result {
        guard !texts.isEmpty else { throw PickError.nothingPicked }

        var picked: [Kind: [String]] = [:]
        for text in texts {
            guard let fileKind = kind(of: text) else { throw PickError.unrecognized }
            guard fileKind == .ebayOrders || picked[fileKind] == nil else {
                throw PickError.pickedTwice(fileKind.label)
            }
            picked[fileKind, default: []].append(text)
        }
        if picked[.pullSheet] != nil, picked[.orderList] == nil { throw PickError.pullSheetAlone }

        var result = Result(contents: SalesOrderCSV.Contents(orders: [], unreadableRows: []))
        var seen: Set<String> = []

        func add(_ kind: Kind, _ contents: SalesOrderCSV.Contents) {
            result.kinds.append(kind)
            result.contents.unreadableRows += contents.unreadableRows
            // One order per number, and not per channel and number: everything
            // downstream — the match, the removal, the row in the sheet — keys
            // on the number alone, so two orders sharing one would be created
            // twice. The first file read keeps its money and its cards.
            for order in contents.orders where seen.insert(order.orderId).inserted {
                result.contents.orders.append(order)
            }
        }

        if let orderList = picked[.orderList]?.first {
            let joined = try TCGplayerOrderExports.join(orderList: orderList, pullSheet: picked[.pullSheet]?.first)
            result.ordersWithoutCards = joined.ordersWithoutCards
            result.unknownOrders = joined.unknownOrders
            add(.orderList, joined.contents)
            if picked[.pullSheet] != nil { result.kinds.append(.pullSheet) }
        }
        for ebay in picked[.ebayOrders] ?? [] {
            add(.ebayOrders, try EbayOrdersCSV.read(ebay))
        }

        result.contents.unreadableRows.sort { ($0.file, $0.line) < ($1.file, $1.line) }
        return result
    }
}
