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
                    )
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
/// The `listed` tag is what keeps `TCGplayerExportSheet` from uploading the
/// copy a second time. The import never removes a tag or a card. A file that
/// lists fewer copies than he holds leaves the other copies alone.
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

            let taken = (pool[productId] ?? [])
                .filter { !used.contains($0.id) && wanted.fits($0) }
                .sorted(by: holdOrder)
                .prefix(row.line.quantity)
            used.formUnion(taken.map(\.id))

            plan.lines.append(Line(
                row: row, productId: productId, condition: condition, printing: printing,
                alreadyListed: taken.filter { CardTagIndex.has(ReservedTag.listed, on: $0) }.map(\.id),
                toTag: taken.filter { !CardTagIndex.has(ReservedTag.listed, on: $0) }.map(\.id),
                toAdd: row.line.quantity - taken.count
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

    /// `costCents` is his total for the added cards. It splits evenly, the way
    /// a cost typed in `AddToInventorySheet` does. Nil adds them with no cost.
    @discardableResult
    static func apply(_ plan: Plan, costCents: Int?, context: ModelContext) throws -> Report {
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

        if let costCents {
            for (card, share) in zip(added, Allocation.splitEqually(costCents, into: added.count)) {
                card.acquisitionBasisCents = share
                card.basisIsManual = true
            }
        }
        CardTagEditor(context: context).add(ReservedTag.listed, to: tagged + added)
        try context.save()
        return Report(tagged: tagged.count, added: added.count)
    }
}

/// The pricing export against the cards the listing export would upload.
///
/// TCGplayer takes a copy off its stock the moment a buyer pays, so the
/// pricing export counts what is still for sale, open orders included. He lists
/// some cards by hand, and he often has open orders the app has not imported.
/// The listing export uploads only copies with no `listed` tag, so only those
/// copies need a decision:
///
/// - **To tag.** TCGplayer has more stock than he has tagged. He listed those
///   copies by hand, so they take the tag.
/// - **To check.** The other untagged copies of a SKU TCGplayer has listed.
///   Probably a hand listing that sold, but a copy he never listed looks the
///   same, so he decides.
///
/// Tagged copies beyond the stock sold on TCGplayer. The export already leaves
/// them unticked, so they are only counted.
@MainActor
enum TCGplayerStockCheck {
    struct Result: Equatable {
        var toTag: [UUID] = []
        var toCheck: Set<UUID> = []
        var soldOnTCGplayer = 0
        /// Rows with stock that the catalog cannot name, or with a condition
        /// the app does not read.
        var unmatchedRows = 0
        var unreadableRows: [Int] = []
    }

    static func check(_ contents: TCGplayerPricingCSV.Contents, cards: [OwnedCard], products: [Int: Int]) -> Result {
        var result = Result(unreadableRows: contents.unreadableRows)
        let pool = Dictionary(grouping: cards.filter(SalesOrderImport.isSellable), by: \.productId)
        var used: Set<UUID> = []
        // Rows with stock first, so a copy with no printing counts against stock
        // before it counts against a SKU that has none.
        for row in contents.rows + contents.emptyRows {
            let wanted = SoldCondition.parse(row.line.condition, channel: .tcgplayer)
            guard let productId = products[row.skuId], wanted.condition != nil, wanted.printing != nil else {
                if row.line.quantity > 0 { result.unmatchedRows += 1 }
                continue
            }
            let copies = (pool[productId] ?? []).filter { !used.contains($0.id) && wanted.fits($0) }
            used.formUnion(copies.map(\.id))

            let tagged = copies.filter { CardTagIndex.has(ReservedTag.listed, on: $0) }
            let untagged = copies
                .filter { !CardTagIndex.has(ReservedTag.listed, on: $0) }
                .sorted { ($0.acquiredAt, $0.id.uuidString) < ($1.acquiredAt, $1.id.uuidString) }
            let stock = row.line.quantity
            result.soldOnTCGplayer += max(0, tagged.count - stock)
            let handListed = max(0, stock - tagged.count)
            result.toTag += untagged.prefix(handListed).map(\.id)
            result.toCheck.formUnion(untagged.dropFirst(handListed).map(\.id))
        }
        return result
    }
}
