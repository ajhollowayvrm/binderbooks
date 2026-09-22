import Foundation
import GRDB
import SwiftData

/// Seller Portal's pricing export, read into the SKUs that have stock.
///
/// One row is one SKU: one product in one condition, printing, and language.
/// "Total Quantity" is the copies the store lists now. The file holds every SKU
/// the store ever listed, so most rows say 0. The same file with a second
/// export joined under it reads the same way.
enum TCGplayerPricingCSV {
    struct Row: Equatable, Sendable, Identifiable {
        /// The row's line in the file, with the header as line 1.
        var lineNumber: Int
        var skuId: Int
        /// The row in the shape `SalesOrderCatalog` reads. Its quantity is
        /// "Total Quantity".
        var line: SalesOrderCSV.Line
        /// "TCG Marketplace Price", his own price now. A row that takes stock
        /// off keeps it, because the import requires a price on every row.
        var marketplaceCents: Int? = nil

        var id: Int { skuId }
    }

    struct Contents: Equatable, Sendable {
        /// The SKUs with stock, in file order.
        var rows: [Row]
        /// Every SKU in the file, with stock or without.
        var skuCount: Int
        /// Line numbers in the file, with the header as line 1.
        var unreadableRows: [Int]
        /// The SKUs TCGplayer listed once and has no stock for now. The stock
        /// check reads them. The import does not.
        var emptyRows: [Row] = []

        var copyCount: Int { rows.reduce(0) { $0 + $1.line.quantity } }
    }

    enum ReadError: LocalizedError, Equatable {
        case missingColumns([String])

        var errorDescription: String? {
            switch self {
            case .missingColumns(let names):
                return "This is not a TCGplayer pricing export. It has no \(names.joined(separator: ", ")) column."
            }
        }
    }

    static let requiredColumns = ["TCGplayer Id", "Product Line", "Set Name", "Product Name", "Number", "Condition", "Total Quantity"]

    static func read(_ text: String) throws -> Contents {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        let table = SalesOrderCSV.rows(body)
        let header = (table.first ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
        let column = Dictionary(header.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let missing = requiredColumns.filter { column[$0] == nil }
        guard missing.isEmpty else { throw ReadError.missingColumns(missing) }

        var contents = Contents(rows: [], skuCount: 0, unreadableRows: [])
        var seen: Set<String> = []
        for (offset, row) in table.dropFirst().enumerated() {
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            func value(_ name: String) -> String {
                guard let index = column[name], index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespaces)
            }

            let idText = value("TCGplayer Id")
            guard !idText.isEmpty, let quantity = Int(value("Total Quantity")), quantity >= 0 else {
                contents.unreadableRows.append(offset + 2)
                continue
            }
            // Two joined exports can hold the same SKU. Both rows report the
            // same stock, so the first one stands and the stock is not doubled.
            guard seen.insert(idText).inserted else { continue }
            contents.skuCount += 1
            // The stock decides first. His export holds 24 rows with an id such
            // as "C-4505111", and every one of them has no stock.
            let skuId = Int(idText)
            func makeRow(_ skuId: Int) -> Row {
                Row(
                    lineNumber: offset + 2,
                    skuId: skuId,
                    line: SalesOrderCSV.Line(
                        productLine: value("Product Line"), setName: value("Set Name"), number: value("Number"),
                        productName: value("Product Name"), condition: value("Condition"), skuId: skuId, quantity: quantity
                    ),
                    marketplaceCents: cents(value("TCG Marketplace Price"))
                )
            }
            guard quantity > 0 else {
                if let skuId { contents.emptyRows.append(makeRow(skuId)) }
                continue
            }
            guard let skuId else {
                contents.unreadableRows.append(offset + 2)
                continue
            }
            contents.rows.append(makeRow(skuId))
        }
        return contents
    }

    /// The export writes four decimals, "44.0000", which `Money.cents` refuses.
    static func cents(_ text: String) -> Int? {
        guard !text.isEmpty, let value = Decimal(string: text) else { return nil }
        return NSDecimalNumber(decimal: value * 100).rounding(accordingToBehavior: nil).intValue
    }

    /// The catalog product behind each SKU, keyed by SKU id. The file names the
    /// set and the number the way a sold-orders row does, so the same lookup
    /// finds the product.
    static func products(_ db: Database, rows: [Row]) throws -> [Int: Int] {
        let categories = try SalesOrderCatalog.categoryIds(db)
        var out: [Int: Int] = [:]
        for row in rows {
            if let productId = try SalesOrderCatalog.tcgplayerProduct(db, line: row.line, categories: categories) {
                out[row.skuId] = productId
            }
        }
        return out
    }
}

/// Brings the stock his TCGplayer store lists onto the inventory, tagged `listed`.
///
/// Each copy goes to one of three places. The copies he already holds count
/// first, so a card that is on the books and on TCGplayer is never added twice:
///
/// - **Already listed.** A held copy carries the `listed` tag. Nothing changes.
/// - **To tag.** A held copy has no `listed` tag. It takes the tag.
/// - **To add.** No held copy is left. The import adds a card with the tag.
///
/// The import never removes a tag or a card. A file that lists fewer copies
/// than he holds leaves the other copies alone.
@MainActor
enum TCGplayerListingImport {
    typealias Row = TCGplayerPricingCSV.Row

    struct Line: Identifiable, Equatable {
        var row: Row
        var productId: Int
        var condition: String
        var printing: String
        /// Held copies that carry the `listed` tag.
        var alreadyListed: [UUID]
        /// Held copies that take the tag.
        var toTag: [UUID]
        /// Copies with no card on the books.
        var toAdd: Int

        var id: Int { row.skuId }
    }

    struct Skipped: Identifiable, Equatable {
        enum Reason: String {
            case notInCatalog = "not in the catalog"
            case unknownCondition = "condition the app does not read"
        }

        var row: Row
        var reason: Reason

        var id: Int { row.skuId }
    }

    struct Plan: Equatable {
        var skuCount = 0
        var lines: [Line] = []
        /// Rows with stock that import nothing.
        var skipped: [Skipped] = []
        var unreadableRows: [Int] = []

        var alreadyListedCount: Int { lines.reduce(0) { $0 + $1.alreadyListed.count } }
        var toTagCount: Int { lines.reduce(0) { $0 + $1.toTag.count } }
        var toAddCount: Int { lines.reduce(0) { $0 + $1.toAdd } }
        var hasWork: Bool { toTagCount + toAddCount > 0 }
    }

    struct Report: Equatable {
        var tagged = 0
        var added = 0

        var summary: String {
            "\(added) \(added == 1 ? "card" : "cards") added to inventory. \(tagged) \(tagged == 1 ? "card" : "cards") you already held tagged listed."
        }
    }

    static func plan(_ contents: TCGplayerPricingCSV.Contents, cards: [OwnedCard], products: [Int: Int]) -> Plan {
        var plan = Plan(skuCount: contents.skuCount, unreadableRows: contents.unreadableRows)
        let pool = Dictionary(grouping: cards.filter(SalesOrderImport.isSellable), by: \.productId)
        var used: Set<UUID> = []

        for row in contents.rows {
            guard let productId = products[row.skuId] else {
                plan.skipped.append(Skipped(row: row, reason: .notInCatalog))
                continue
            }
            // A raw SKU never names a grader, so `fits` also keeps slabs and
            // cards at a grader out.
            let wanted = SoldCondition.parse(row.line.condition, channel: .tcgplayer)
            guard let condition = wanted.condition, let printing = wanted.printing else {
                plan.skipped.append(Skipped(row: row, reason: .unknownCondition))
                continue
            }

            // One card record can hold several copies, so the stock counts
            // against copies, not against records.
            var taken: [OwnedCard] = []
            var covered = 0
            for card in (pool[productId] ?? []).filter({ !used.contains($0.id) && wanted.fits($0) }).sorted(by: holdOrder) {
                guard covered < row.line.quantity else { break }
                taken.append(card)
                covered += max(1, card.quantity)
            }
            used.formUnion(taken.map(\.id))

            plan.lines.append(Line(
                row: row, productId: productId, condition: condition, printing: printing,
                alreadyListed: taken.filter { CardTagIndex.has(ReservedTag.listed, on: $0) }.map(\.id),
                toTag: taken.filter { !CardTagIndex.has(ReservedTag.listed, on: $0) }.map(\.id),
                toAdd: max(0, row.line.quantity - covered)
            ))
        }
        return plan
    }

    /// A copy he tagged listed first, because that tag already stands for a
    /// listing. Then a copy that names the printing, then the oldest.
    private static func holdOrder(_ a: OwnedCard, _ b: OwnedCard) -> Bool {
        func key(_ card: OwnedCard) -> (Int, Int, Date, String) {
            (CardTagIndex.has(ReservedTag.listed, on: card) ? 0 : 1, card.printing.isEmpty ? 1 : 0, card.acquiredAt, card.id.uuidString)
        }
        return key(a) < key(b)
    }

    /// Tags the held cards listed and adds the new cards, also tagged listed.
    /// A new card has no purchase and no cost.
    @discardableResult
    static func apply(_ plan: Plan, context: ModelContext) throws -> Report {
        let cards = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<OwnedCard>()).map { ($0.id, $0) })
        var tagged: [OwnedCard] = []
        var added: [OwnedCard] = []

        for line in plan.lines {
            for id in line.toTag {
                guard let card = cards[id], !CardTagIndex.isSold(card), !CardTagIndex.has(ReservedTag.listed, on: card) else { continue }
                // The file names the SKU, so a card with no printing learns it
                // here. The listing export skips a card with no printing.
                if card.printing.isEmpty { card.printing = line.printing }
                if card.skuId == nil { card.skuId = line.row.skuId }
                tagged.append(card)
            }
            for _ in 0..<line.toAdd {
                let card = OwnedCard(productId: line.productId, printing: line.printing, condition: line.condition, confidence: .certain)
                card.skuId = line.row.skuId
                context.insert(card)
                added.append(card)
            }
        }

        CardTagEditor(context: context).add(ReservedTag.listed, to: tagged + added)
        try context.save()
        return Report(tagged: tagged.count, added: added.count)
    }
}
