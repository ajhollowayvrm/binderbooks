import Foundation

/// Turns inventory into the CSV that TCGplayer's Seller Portal imports.
///
/// The import matches each row on its "TCGplayer Id", which is a SKU: one
/// product in one condition, printing, and language. Only three columns change
/// anything: the id, "Add to Quantity", and "TCG Marketplace Price". The other
/// thirteen are TCGplayer's reference columns. The import requires all sixteen,
/// in this order, so the file keeps them and fills what the app knows.
///
/// "Add to Quantity" adds to the stock already listed, and a negative value
/// takes stock off. So the file needs what TCGplayer lists now, from Seller
/// Portal's pricing export. Each row adds the copies he holds less the copies
/// TCGplayer lists: one held and one listed writes 0, which changes only the
/// price. A SKU TCGplayer lists and he no longer holds takes its stock off.
enum TCGplayerListingExport {
    /// What he charges a buyer to ship one card, as typed. Empty is zero.
    static let shippingDefaultsKey = "tcgplayerShippingChargedCents"

    static let header = [
        "TCGplayer Id", "Product Line", "Set Name", "Product Name", "Title", "Number", "Rarity", "Condition",
        "TCG Market Price", "TCG Direct Low", "TCG Low Price With Shipping", "TCG Low Price",
        "Total Quantity", "Add to Quantity", "TCG Marketplace Price", "Photo URL",
    ]

    /// TCGplayer rejects a price under one cent.
    static let minimumPriceCents = 1

    // MARK: - Which cards

    /// Why a card stays out of the file. The first four are AJ's rules, from
    /// 2026-09-11. A slab is not a raw SKU, so a slab listed as Near Mint
    /// misdescribes the card.
    enum SkipReason: String, CaseIterable, Sendable {
        case slab = "graded slab"
        case sealed = "sealed product"
        case personal = "personal collection"
        case atGrader = "at a grader"
        case sold
        case onOrder = "on order"
        case notInCatalog = "not in the catalog"
        case noPrinting = "no printing chosen"
        case unknownCondition = "condition TCGplayer does not use"
    }

    /// Nil when the card can be listed. The printing is checked later, in
    /// `plan`, because it needs the catalog's price rows.
    static func skipReason(for card: OwnedCard, hit: SearchHit?) -> SkipReason? {
        if CardTagIndex.isSold(card) { return .sold }
        // Not in his hands yet, so there is nothing to ship. See `OnOrder`.
        if OnOrder.isOnOrder(card) { return .onOrder }
        guard card.isIdentified, let hit else { return .notInCatalog }
        if isGraded(card) { return .slab }
        if card.isSealedSelf || hit.isSealed { return .sealed }
        if card.isPersonalCollection { return .personal }
        if ReservedTag.allAtGrader.contains(where: { CardTagIndex.has($0, on: card) }) { return .atGrader }
        if CardCondition(rawValue: card.condition) == nil { return .unknownCondition }
        return nil
    }

    /// True for every graded card. TCGplayer sells raw cards only, so a graded
    /// card has no SKU there at all, and listing one as Near Mint
    /// misdescribes it.
    ///
    /// `OwnedCard.isSlabbed` asks for a cert number, or a grader and a grade
    /// together. A card that carries only one of the two, or only the `graded`
    /// label, is graded all the same, and this reads all four signals.
    static func isGraded(_ card: OwnedCard) -> Bool {
        card.isSlabbed || card.certNumber != nil || card.graderRaw != nil || card.gradeLabel != nil
            || CardTagIndex.has(ReservedTag.graded, on: card)
    }

    /// The card's own printing, or the product's only printing when the card
    /// names none. Nil when the product has several and the card names none,
    /// because a guess lists the wrong SKU.
    static func printing(for card: OwnedCard, prices: [ProductPrice]) -> String? {
        if !card.printing.isEmpty { return card.printing }
        let names = Set(prices.map(\.subTypeName))
        return names.count == 1 ? names.first : nil
    }

    /// Every reason for one inventory row: the card's own, then its printing.
    /// The picker reads this, so a card it offers is a card `plan` keeps.
    static func skipReason(for row: InventoryRow, prices: [Int: [ProductPrice]]) -> SkipReason? {
        if let reason = skipReason(for: row.card, hit: row.hit) { return reason }
        guard let hit = row.hit, printing(for: row.card, prices: prices[hit.productId] ?? []) != nil else { return .noPrinting }
        return nil
    }

    /// TCGplayer's language name. The catalog files Japanese cards under their
    /// own category; `OwnedCard.language` is "en" on every row.
    static func language(categoryId: Int) -> String {
        categoryId == TCGCategory.pokemonJapan ? "Japanese" : "English"
    }

    // MARK: - Lines

    struct SkuKey: Hashable, Sendable {
        var productId: Int
        var condition: String
        var printing: String
        var language: String
    }

    /// One SKU and every copy of it. The import rejects a SKU that appears
    /// twice, so copies merge here.
    struct Line: Identifiable, Equatable, Sendable {
        var key: SkuKey
        var hit: SearchHit
        /// The copies he holds.
        var quantity: Int
        var marketCents: Int?
        var cardIds: [UUID]
        /// The SKU's row in the pricing export. Nil when TCGplayer never
        /// listed it.
        var stock: TCGplayerPricingCSV.Row? = nil

        var id: SkuKey { key }
        /// The copies TCGplayer lists now.
        var listed: Int { stock?.line.quantity ?? 0 }
        /// "Add to Quantity". Negative when TCGplayer lists more than he holds.
        var addQuantity: Int { quantity - listed }
        /// TCGplayer listed the SKU before and has none now. A copy that sold
        /// there and is not marked sold looks the same, so the sheet says so.
        var listedBefore: Bool { stock != nil && listed == 0 }
    }

    struct Plan: Equatable {
        var lines: [Line] = []
        var skipped: [SkipReason: Int] = [:]
    }

    // MARK: - What TCGplayer lists now

    /// A SKU as both files name it. The product fixes the language, because
    /// the catalog files Japanese cards under their own category.
    struct StockKey: Hashable, Sendable {
        var productId: Int
        var condition: String
        var printing: String

        init(productId: Int, condition: String, printing: String) {
            self.productId = productId
            self.condition = condition.lowercased()
            self.printing = printing.lowercased()
        }

        init(_ key: SkuKey) {
            self.init(productId: key.productId, condition: key.condition, printing: key.printing)
        }
    }

    /// Seller Portal's pricing export, keyed so a line finds its SKU.
    struct Stock: Equatable, Sendable {
        /// Every SKU the catalog names, with stock or without.
        var rows: [StockKey: TCGplayerPricingCSV.Row] = [:]
        /// Rows with stock that the catalog cannot name, or with a condition
        /// the app does not read. The file leaves them alone.
        var unmatched: [TCGplayerPricingCSV.Row] = []
        var unreadableRows: [Int] = []

        func row(for key: SkuKey) -> TCGplayerPricingCSV.Row? { rows[StockKey(key)] }
    }

    static func stock(_ contents: TCGplayerPricingCSV.Contents, products: [Int: Int]) -> Stock {
        var stock = Stock(unreadableRows: contents.unreadableRows)
        for row in contents.rows + contents.emptyRows {
            let wanted = SoldCondition.parse(row.line.condition, channel: .tcgplayer)
            guard let productId = products[row.skuId], let condition = wanted.condition, let printing = wanted.printing else {
                if row.line.quantity > 0 { stock.unmatched.append(row) }
                continue
            }
            stock.rows[StockKey(productId: productId, condition: condition, printing: printing)] = row
        }
        return stock
    }

    /// The SKUs TCGplayer lists that no listable card on the books fills.
    /// Their rows take the stock off. `rows` is the whole inventory, not the
    /// cards he ticked, so an unticked card keeps its SKU on TCGplayer.
    ///
    /// A card with no printing chosen could be any printing of its product,
    /// so that product's SKUs go to `unsure` and stay on TCGplayer.
    static func removals(_ stock: Stock, rows: [InventoryRow], prices: [Int: [ProductPrice]]) -> (remove: [TCGplayerPricingCSV.Row], unsure: [TCGplayerPricingCSV.Row]) {
        var held: Set<StockKey> = []
        var unsureProducts: Set<Int> = []
        for row in rows {
            let reason = skipReason(for: row, prices: prices)
            if reason == .noPrinting, let hit = row.hit { unsureProducts.insert(hit.productId) }
            guard reason == nil, let hit = row.hit, let printing = printing(for: row.card, prices: prices[hit.productId] ?? []) else { continue }
            held.insert(StockKey(productId: hit.productId, condition: row.card.condition, printing: printing))
        }
        var remove: [TCGplayerPricingCSV.Row] = []
        var unsure: [TCGplayerPricingCSV.Row] = []
        for (key, row) in stock.rows where row.line.quantity > 0 && !held.contains(key) {
            if unsureProducts.contains(key.productId) { unsure.append(row) } else { remove.append(row) }
        }
        return (remove.sorted { $0.lineNumber < $1.lineNumber }, unsure.sorted { $0.lineNumber < $1.lineNumber })
    }

    /// `holdingOne` names the cards that must leave one copy behind, for a set
    /// he is master setting. A card with one copy drops out of the file. See
    /// `MasterSetHold`.
    static func plan(_ rows: [InventoryRow], prices: [Int: [ProductPrice]], holdingOne: Set<UUID> = [], stock: Stock = Stock()) -> Plan {
        var plan = Plan()
        var byKey: [SkuKey: Line] = [:]
        for row in rows {
            if let reason = skipReason(for: row.card, hit: row.hit) {
                plan.skipped[reason, default: 0] += 1
                continue
            }
            guard let hit = row.hit else { continue }
            let rows = prices[hit.productId] ?? []
            guard let printing = printing(for: row.card, prices: rows) else {
                plan.skipped[.noPrinting, default: 0] += 1
                continue
            }
            let key = SkuKey(productId: hit.productId, condition: row.card.condition, printing: printing, language: language(categoryId: hit.categoryId))
            var line = byKey[key] ?? Line(
                key: key, hit: hit, quantity: 0,
                marketCents: rows.first { $0.subTypeName == printing }?.marketCents,
                cardIds: [],
                stock: stock.row(for: key)
            )
            var quantity = max(1, row.card.quantity)
            if holdingOne.contains(row.card.id) { quantity -= 1 }
            // Every copy stays for the master set, so the card is not in the
            // file and must not be tagged listed.
            guard quantity > 0 else { continue }
            line.quantity += quantity
            line.cardIds.append(row.card.id)
            byKey[key] = line
        }
        plan.lines = byKey.values.sorted(by: fileOrder)
        return plan
    }

    /// Set, then number, then condition. The order of a binder page, so he can
    /// read the file against the cards.
    private static func fileOrder(_ a: Line, _ b: Line) -> Bool {
        if a.hit.setName != b.hit.setName { return a.hit.setName < b.hit.setName }
        if a.hit.numberNum != b.hit.numberNum { return (a.hit.numberNum ?? .max) < (b.hit.numberNum ?? .max) }
        if a.hit.name != b.hit.name { return a.hit.name < b.hit.name }
        if a.key.printing != b.key.printing { return a.key.printing < b.key.printing }
        return conditionRank(a.key.condition) < conditionRank(b.key.condition)
    }

    private static func conditionRank(_ condition: String) -> Int {
        CardCondition.allCases.firstIndex { $0.rawValue == condition } ?? CardCondition.allCases.count
    }

    static func sku(in skus: [TCGplayerMarketClient.Sku], for key: SkuKey) -> TCGplayerMarketClient.Sku? {
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
        return skus.first { same($0.condition, key.condition) && same($0.printing, key.printing) && same($0.language, key.language) }
    }

    // MARK: - Price

    enum PriceSource: Equatable, Sendable {
        /// Matched to the cheapest live listing of the same SKU.
        case liveLow
        /// Nobody sells the SKU, so the catalog's market price.
        case market
        /// Worth $5 or more, so the market price, whatever the cheapest
        /// listing asks.
        case atMarket
    }

    /// AJ's rule, 2026-09-15: a card with no listing under 20 cents is not
    /// worth an order. A single cheap order leaves about 31 cents after fees
    /// and postage, nearly all of it from the shipping he charges.
    ///
    /// He sets the figure in the export sheet, because what an order is worth
    /// moves with the fees and with what he charges to ship. Twenty cents is
    /// where it started.
    static let defaultFloorCents = 20
    static let floorDefaultsKey = "tcgplayerFloorCents"

    /// AJ's rule, 2026-09-11, amended 2026-09-15. At $5 and up the card lists
    /// at its market price and waits: matching the cheapest listing sold nine
    /// such cards $19 under market on one upload. Under $5 it matches the
    /// cheapest listing's price plus its shipping, less his own shipping, so
    /// the buyer's total for his copy equals the cheapest total. With no live
    /// listing the price is the market price. Nil when neither exists.
    static func price(lowest: TCGplayerMarketClient.Listing?, marketCents: Int?, shippingChargedCents: Int) -> (cents: Int, source: PriceSource)? {
        if let marketCents, marketCents >= ProductPrice.marketRuleCents {
            return (marketCents, .atMarket)
        }
        if let lowest {
            return (max(minimumPriceCents, lowest.totalCents - shippingChargedCents), .liveLow)
        }
        if let marketCents, marketCents > 0 {
            return (marketCents, .market)
        }
        return nil
    }

    /// True when the card stays out of the file: its cheapest listing, not
    /// counting shipping, is under the floor. With no listing the market price
    /// decides. A card worth $5 or more is never under it. The builder asks
    /// only about a SKU TCGplayer does not list, because a listed SKU needs
    /// its row to keep the stock right.
    static func isBelowFloor(lowest: TCGplayerMarketClient.Listing?, marketCents: Int?, floorCents: Int = defaultFloorCents) -> Bool {
        if let marketCents, marketCents >= ProductPrice.marketRuleCents { return false }
        if let lowest { return lowest.priceCents < floorCents }
        return (marketCents ?? 0) < floorCents
    }

    struct Priced: Identifiable, Equatable, Sendable {
        var line: Line
        var skuId: Int
        var priceCents: Int
        var source: PriceSource
        var lowest: TCGplayerMarketClient.Listing?
        /// TCGplayer's exact product name. The import rejects the catalog's
        /// name when TCGplayer's has the number on it. Nil falls back to it.
        var productName: String? = nil

        var id: SkuKey { line.key }
    }

    // MARK: - The file

    /// CRLF line ends, the way a spreadsheet writes a CSV.
    /// `removals` are pricing-export rows whose stock comes off. They keep
    /// TCGplayer's own names and his own price.
    static func csv(_ rows: [Priced], removals: [TCGplayerPricingCSV.Row] = [], categoryNames: [Int: String]) -> String {
        var lines = [header.map(field).joined(separator: ",")]
        for row in rows {
            let hit = row.line.hit
            let values = [
                String(row.skuId),
                categoryNames[hit.categoryId] ?? "",
                hit.setName,
                row.productName ?? hit.name,
                "",
                hit.number ?? "",
                hit.rarity ?? "",
                conditionText(row.line.key),
                row.line.marketCents.map(Money.fieldText) ?? "",
                "",
                row.lowest.map { Money.fieldText($0.totalCents) } ?? "",
                row.lowest.map { Money.fieldText($0.priceCents) } ?? "",
                "",
                String(row.line.addQuantity),
                Money.fieldText(row.priceCents),
                "",
            ]
            lines.append(values.map(field).joined(separator: ","))
        }
        for row in removals {
            let line = row.line
            let values = [
                String(row.skuId), line.productLine, line.setName, line.productName, "", line.number, "", line.condition,
                "", "", "", "", "",
                String(-line.quantity),
                Money.fieldText(max(minimumPriceCents, row.marketplaceCents ?? 0)),
                "",
            ]
            lines.append(values.map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// TCGplayer's own export writes "Near Mint Holofoil", and a plain
    /// "Near Mint" for the normal printing.
    static func conditionText(_ key: SkuKey) -> String {
        var text = key.condition
        if key.printing != "Normal" { text += " \(key.printing)" }
        if key.language != "English" { text += " - \(key.language)" }
        return text
    }

    private static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func suggestedFileName(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return "tcgplayer-listings-\(f.string(from: now)).csv"
    }

    // MARK: - Report

    struct Report: Equatable {
        var liveLow = 0
        var market = 0
        var atMarket = 0
        var belowFloor = 0
        /// The floor this run used, so the summary names his figure.
        var floorCents = defaultFloorCents
        var noSku = 0
        var unpriced = 0
        var failed = 0
        var skipped: [SkipReason: Int] = [:]
        var stoppedBy: String?

        var summary: String {
            var parts = ["\(liveLow + market + atMarket) rows priced: \(atMarket) at market because they are worth $5 or more, \(liveLow) at the cheapest listing, \(market) at market with no listing"]
            if belowFloor > 0 { parts.append("\(belowFloor) left out because the cheapest listing is under \(floorCents.asCurrency)") }
            if noSku > 0 { parts.append("\(noSku) have no SKU on TCGplayer") }
            if unpriced > 0 { parts.append("\(unpriced) have no listing and no market price") }
            if failed > 0 { parts.append("\(failed) lookups failed") }
            for reason in SkipReason.allCases {
                if let count = skipped[reason], count > 0 { parts.append("\(count) skipped: \(reason.rawValue)") }
            }
            if let stoppedBy { parts.append("Stopped: \(stoppedBy)") }
            return parts.joined(separator: ". ") + "."
        }
    }
}
