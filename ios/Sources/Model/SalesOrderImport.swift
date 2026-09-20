import Foundation
import GRDB
import SwiftData

/// Brings a sold-orders CSV onto his books.
///
/// The import works on the live store, not through a collection file.
/// `CollectionExport.apply` can only add and overwrite rows, so it could not
/// remove a duplicate, and it would overwrite every card he edited on the phone
/// after the seed import.
///
/// Each order goes to one of four places:
///
/// - **Already on the books.** A sale carries its order number. Nothing changes.
/// - **Matched.** A sale with no order number is the same order: the same money,
///   or the same cards, within days. The sale takes the order number, and the
///   file's channel when the two disagree. Its money stays as he recorded it.
/// - **New.** No sale is the order. The import creates one with estimated
///   costs. Each card links to his oldest unsold copy and is tagged sold.
/// - **To remove.** A canceled order that is on the books, or a second sale of
///   an order already matched. Nothing is removed unless he switches it on.
///
/// The seed ledger shows why each rule exists. It files two eBay slabs under
/// TCGplayer, records two orders twice, and books a canceled order as revenue.
@MainActor
enum SalesOrderImport {
    typealias Order = SalesOrderCSV.Order

    struct Match: Identifiable, Equatable {
        var order: Order
        var saleId: UUID
        /// The sale's channel before, when the file names another one.
        var channelBefore: String?
        /// True when the sale recorded no cards, so the file's cards are added.
        var addsLines: Bool

        var id: String { order.orderId }
    }

    struct NewLine: Equatable {
        var describedAs: String
        var productId: Int?
        var cardId: UUID?
        /// Nil when no card is linked, or the card has no cost.
        var basisCents: Int?
        var skuId: Int?
    }

    struct NewSale: Identifiable, Equatable {
        var order: Order
        var feeCents: Int
        var postageCents: Int
        var lines: [NewLine]

        var id: String { order.orderId }
        var linkedCount: Int { lines.filter { $0.cardId != nil }.count }
    }

    struct Removal: Identifiable, Equatable {
        enum Reason: Equatable {
            case canceled(orderId: String)
            case duplicate(orderId: String)
        }

        var saleId: UUID
        var reason: Reason
        var soldAt: Date
        var channelRaw: String
        var grossCents: Int
        var describedAs: String
        var linkedCards: Int

        var id: UUID { saleId }
    }

    struct Plan: Equatable {
        var orderCount = 0
        var alreadyOnBooks = 0
        var matches: [Match] = []
        var newSales: [NewSale] = []
        var removals: [Removal] = []
        var canceledNotOnBooks = 0
        var unreadableRows: [SalesOrderCSV.UnreadableRow] = []
        /// Cards on new orders that the catalog could not name. They import
        /// with the file's description and no link.
        var unidentifiedCards = 0

        var channelCorrections: [Match] { matches.filter { $0.channelBefore != nil } }
    }

    struct Report: Equatable {
        var numbered = 0
        var channelsCorrected = 0
        var created = 0
        var linesAdded = 0
        var cardsLinked = 0
        var removed = 0
        var cardsReturned = 0

        var summary: String {
            var parts = ["\(created) new \(created == 1 ? "order" : "orders"), with \(cardsLinked) cards linked to inventory"]
            parts.append("\(numbered) existing sales took their order number")
            if channelsCorrected > 0 { parts.append("\(channelsCorrected) moved to the file's channel") }
            if linesAdded > 0 { parts.append("\(linesAdded) cards added to sales that recorded none") }
            if removed > 0 { parts.append("\(removed) sales removed, and \(cardsReturned) cards went back to inventory") }
            return parts.joined(separator: ". ") + "."
        }
    }

    /// How far the day on his books may sit from the order's day. He often
    /// recorded a sale when it paid out, up to 8 days after the order.
    static let daysBefore = 3
    static let daysAfter = 10

    /// What his books may add to an eBay item price, over and above the order's
    /// own total: the tax, which no eBay file carries. It was also the buyer's
    /// shipping back when the eBay rows carried no shipping either; eBay's All
    /// Orders Report does carry it, so for those orders this allowance is tax
    /// alone and the band is wider than it needs to be. A wider band is safe
    /// here because an eBay order only ever matches a sale that names one of
    /// its cards — see `score`.
    static let ebayAllowanceCents = 600

    // MARK: - Plan

    static func plan(
        _ contents: SalesOrderCSV.Contents,
        sales: [Sale],
        cards: [OwnedCard],
        products: [SalesOrderCatalog.CopyKey: Int]
    ) -> Plan {
        var plan = Plan(orderCount: contents.orders.count, unreadableRows: contents.unreadableRows)
        let orders = contents.orders.sorted { ($0.soldAt, $0.orderId) < ($1.soldAt, $1.orderId) }

        var numbered: [String: Sale] = [:]
        for sale in sales {
            let id = orderNumber(sale)
            if !id.isEmpty, numbered[id] == nil { numbered[id] = sale }
        }

        // The order number is on a sale already.
        var settled: [String: UUID] = [:]
        var open: [Order] = []
        for order in orders {
            guard let sale = numbered[order.orderId] else {
                open.append(order)
                continue
            }
            settled[order.orderId] = sale.id
            if order.isCanceled {
                plan.removals.append(removal(sale, .canceled(orderId: order.orderId)))
            } else {
                plan.alreadyOnBooks += 1
            }
        }

        // The rest against sales with no order number, best pair first, so a
        // sale that names the cards wins over one that recorded only a price.
        let unnumbered = sales.filter { orderNumber($0).isEmpty }
        var pairs: [(order: Order, sale: Sale, score: Score)] = []
        for order in open {
            for sale in unnumbered {
                if let score = score(order, sale) { pairs.append((order, sale, score)) }
            }
        }
        pairs.sort { $0.score < $1.score }

        var takenSales: Set<UUID> = []
        var matchedOrders: Set<String> = []
        var channelOf: [UUID: String] = [:]
        for pair in pairs where !takenSales.contains(pair.sale.id) && !matchedOrders.contains(pair.order.orderId) {
            takenSales.insert(pair.sale.id)
            matchedOrders.insert(pair.order.orderId)
            settled[pair.order.orderId] = pair.sale.id
            if pair.order.isCanceled {
                plan.removals.append(removal(pair.sale, .canceled(orderId: pair.order.orderId)))
                continue
            }
            let channel = pair.order.channel.rawValue
            let before = pair.sale.channelRaw == channel ? nil : pair.sale.channelRaw
            if before != nil { channelOf[pair.sale.id] = channel }
            plan.matches.append(Match(order: pair.order, saleId: pair.sale.id, channelBefore: before, addsLines: pair.sale.lines.isEmpty))
        }

        // A sale left over with the same money, on the same days, as an order
        // another sale already is: the order recorded twice.
        let settledOrders = orders.filter { settled[$0.orderId] != nil && !$0.isCanceled }
        for sale in unnumbered where !takenSales.contains(sale.id) {
            let original = settledOrders.first { order in
                guard settled[order.orderId] != sale.id, let score = score(order, sale) else { return false }
                return score.exactAmount && score.names != .disagree
            }
            if let original {
                plan.removals.append(removal(sale, .duplicate(orderId: original.orderId)))
            }
        }

        // New orders. Oldest order first, so each takes his oldest copy.
        let estimate = FeeEstimate.derived(from: sales) { channelOf[$0.id] ?? $0.channelRaw }
        let pool = Dictionary(grouping: cards.filter(isSellable), by: \.productId)
            .mapValues { $0.sorted { ($0.acquiredAt, $0.id.uuidString) < ($1.acquiredAt, $1.id.uuidString) } }
        var used: Set<UUID> = []

        for order in open where !matchedOrders.contains(order.orderId) {
            if order.isCanceled {
                plan.canceledNotOnBooks += 1
                continue
            }
            var lines: [NewLine] = []
            for (index, line) in order.lines.enumerated() {
                let condition = SoldCondition.parse(line.condition, channel: order.channel)
                for copy in 0..<line.quantity {
                    let key = SalesOrderCatalog.CopyKey(orderId: order.orderId, line: index, copy: copy)
                    var new = NewLine(describedAs: line.productName, productId: products[key], skuId: line.skuId)
                    guard let productId = products[key] else {
                        plan.unidentifiedCards += 1
                        lines.append(new)
                        continue
                    }
                    let candidates = (pool[productId] ?? []).filter { !used.contains($0.id) && condition.fits($0) }
                    if let card = candidates.first(where: \.isSlabbed) ?? candidates.first {
                        used.insert(card.id)
                        new.cardId = card.id
                        new.basisCents = card.totalBasisCents > 0 ? card.totalBasisCents : nil
                    }
                    lines.append(new)
                }
            }
            let fit = estimate.fit(for: order.channel.rawValue)
            plan.newSales.append(NewSale(
                order: order,
                feeCents: fit?.feeCents(onCents: order.totalCents) ?? 0,
                postageCents: fit?.postageCents ?? 0,
                lines: lines
            ))
        }
        return plan
    }

    /// A card that is still his to sell.
    static func isSellable(_ card: OwnedCard) -> Bool {
        card.isIdentified && card.isCommitted && !card.isSealedSelf && !card.isPersonalCollection && !CardTagIndex.isSold(card)
    }

    private static func orderNumber(_ sale: Sale) -> String {
        sale.externalOrderId.trimmingCharacters(in: .whitespaces)
    }

    private static func removal(_ sale: Sale, _ reason: Removal.Reason) -> Removal {
        Removal(
            saleId: sale.id, reason: reason, soldAt: sale.soldAt, channelRaw: sale.channelRaw, grossCents: sale.grossCents,
            describedAs: sale.lines.map(\.describedAs).filter { !$0.isEmpty }.joined(separator: ", "),
            linkedCards: sale.lines.filter { $0.card != nil }.count
        )
    }

    // MARK: - Matching

    enum Names: Int, Equatable {
        /// A card the sale names is in the order.
        case agree
        /// The sale names no card.
        case unnamed
        /// The sale names cards, and none is in the order.
        case disagree
    }

    struct Score: Comparable {
        var canceled: Bool
        var names: Names
        var exactAmount: Bool
        var sameChannel: Bool
        var days: Int
        var tieBreak: String

        static func < (a: Score, b: Score) -> Bool {
            (a.canceled ? 1 : 0, a.names.rawValue, a.exactAmount ? 0 : 1, a.sameChannel ? 0 : 1, abs(a.days), a.tieBreak)
                < (b.canceled ? 1 : 0, b.names.rawValue, b.exactAmount ? 0 : 1, b.sameChannel ? 0 : 1, abs(b.days), b.tieBreak)
        }
    }

    /// Nil when the sale cannot be this order.
    static func score(_ order: Order, _ sale: Sale) -> Score? {
        let days = dayCount(from: order.soldAt, to: sale.soldAt)
        guard (-daysBefore...daysAfter).contains(days) else { return nil }

        let names = nameAgreement(order, sale)
        let sameChannel = sale.channelRaw == order.channel.rawValue
        let gross = sale.grossCents
        let exact = gross == order.totalCents || gross == order.productCents
            || gross + sale.shippingChargedCents == order.totalCents

        switch order.channel {
        case .tcgplayer:
            // His TCGplayer rows record the buyer's total to the cent. A price
            // alone is enough on the same channel; across channels the cards
            // must agree too.
            guard exact else { return nil }
            guard sameChannel ? true : names == .agree else { return nil }
        case .ebay:
            // The eBay rows carry the item price only, so the money is close
            // rather than equal, and the cards must agree.
            let near = gross >= order.productCents && gross <= order.totalCents + ebayAllowanceCents
            guard names == .agree, exact || near else { return nil }
        }
        return Score(
            canceled: order.isCanceled, names: names, exactAmount: exact, sameChannel: sameChannel,
            days: days, tieBreak: order.orderId + " " + sale.id.uuidString
        )
    }

    static func nameAgreement(_ order: Order, _ sale: Sale) -> Names {
        let named = sale.lines.map { significantTokens($0.describedAs) }.filter { !$0.isEmpty }
        guard !named.isEmpty else { return .unnamed }
        let orderTokens = order.lines.reduce(into: Set<String>()) { $0.formUnion(significantTokens($1.productName)) }
        return named.contains { $0.isSubset(of: orderTokens) } ? .agree : .disagree
    }

    /// The words of a name, without the short ones. His ledger writes
    /// "Froakie + Frogadier IR" where the eBay title spells out the rarity, and
    /// "ex" or "V" alone tells two cards apart from nothing.
    static func significantTokens(_ text: String) -> Set<String> {
        Set(NameCleaner.clean(text).split(separator: " ").map(String.init).filter { $0.count >= 3 })
    }

    static func dayCount(from a: Date, to b: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: a), to: calendar.startOfDay(for: b)).day ?? 0
    }

    // MARK: - Apply

    /// `removing` holds the ids of the sales he switched on for removal.
    @discardableResult
    static func apply(_ plan: Plan, removing: Set<UUID>, context: ModelContext) throws -> Report {
        var report = Report()
        let sales = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Sale>()).map { ($0.id, $0) })
        let cards = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<OwnedCard>()).map { ($0.id, $0) })
        let editor = CardTagEditor(context: context)

        for match in plan.matches {
            guard let sale = sales[match.saleId], orderNumber(sale).isEmpty else { continue }
            sale.externalOrderId = match.order.orderId
            report.numbered += 1
            if match.channelBefore != nil {
                sale.channelRaw = match.order.channel.rawValue
                report.channelsCorrected += 1
            }
            // The sale is his old record of a card long gone. Its lines say
            // what sold and link nothing, because a link would take a copy he
            // still holds.
            if match.addsLines, sale.lines.isEmpty {
                for line in match.order.lines {
                    for _ in 0..<line.quantity {
                        let added = SaleLine(sale: sale, basisIncomplete: true)
                        added.describedAs = line.productName
                        context.insert(added)
                        report.linesAdded += 1
                    }
                }
            }
        }

        let existing = Set(sales.values.map(orderNumber))
        for new in plan.newSales where !existing.contains(new.order.orderId) {
            let sale = Sale(soldAt: new.order.soldAt, channelRaw: new.order.channel.rawValue, grossCents: new.order.productCents)
            sale.shippingChargedCents = new.order.shippingChargedCents
            sale.marketplaceFeesCents = new.feeCents
            sale.shippingCostCents = new.postageCents
            sale.externalOrderId = new.order.orderId
            // True even with no fit to estimate from: the zeros are not real.
            sale.costsEstimated = true
            context.insert(sale)
            report.created += 1

            var sold: [OwnedCard] = []
            for line in new.lines {
                let card = line.cardId.flatMap { cards[$0] }.flatMap { CardTagIndex.isSold($0) ? nil : $0 }
                let basis = card == nil ? nil : line.basisCents
                let saleLine = SaleLine(sale: sale, card: card, basisCents: basis ?? 0, basisIncomplete: basis == nil)
                saleLine.describedAs = line.describedAs
                context.insert(saleLine)
                if let card {
                    if card.skuId == nil { card.skuId = line.skuId }
                    sold.append(card)
                }
            }
            editor.add(ReservedTag.sold, to: sold)
            report.cardsLinked += sold.count
        }

        let lines = try context.fetch(FetchDescriptor<SaleLine>())
        for removal in plan.removals where removing.contains(removal.saleId) {
            guard let sale = sales[removal.saleId] else { continue }
            // A card goes back only when no other sale sold it.
            let returning = sale.lines.compactMap(\.card).filter { card in
                !lines.contains { $0.card?.id == card.id && $0.sale?.id != sale.id }
            }
            editor.remove(ReservedTag.sold, from: returning)
            for card in returning where card.status == .sold {
                card.status = .owned
            }
            report.cardsReturned += returning.count
            context.delete(sale)
            report.removed += 1
        }

        try context.save()
        return report
    }
}

// MARK: - Condition

/// What the file says about the copy that sold.
///
/// TCGplayer writes a condition and a printing: "Near Mint Reverse Holofoil",
/// with " - Japanese" for a Japanese card. eBay writes a grade, "CGC Pristine
/// 10", or "NM (ungraded)".
struct SoldCondition: Equatable {
    var condition: String?
    var printing: String?
    /// Lower case, the way `OwnedCard.graderRaw` stores it.
    var grader: String?
    var grade: Decimal?
    /// The label has a word beside the number: "Pristine 10", "Gem Mint 10".
    var gradeHasWord = false
    var pristine = false

    private static let graderPattern = #/(?i)\b(psa|cgc|bgs|sgc|tag)\b/#
    private static let gradePattern = #/(\d+(?:\.\d+)?)/#

    static func parse(_ text: String, channel: SalesOrderCSV.Channel) -> SoldCondition {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let match = trimmed.firstMatch(of: graderPattern) {
            let rest = trimmed.replacing(graderPattern, with: "")
            return SoldCondition(
                grader: String(match.1).lowercased(),
                grade: rest.firstMatch(of: gradePattern).flatMap { Decimal(string: String($0.1)) },
                gradeHasWord: rest.contains { $0.isLetter },
                pristine: trimmed.lowercased().contains("pristine")
            )
        }
        guard channel == .tcgplayer else { return SoldCondition() }

        var body = trimmed
        if let dash = body.range(of: " - ") { body = String(body[..<dash.lowerBound]) }
        let names = CardCondition.allCases.map(\.rawValue).sorted { $0.count > $1.count }
        guard let name = names.first(where: { body.lowercased().hasPrefix($0.lowercased()) }) else { return SoldCondition() }
        let printing = body.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
        return SoldCondition(condition: name, printing: printing.isEmpty ? "Normal" : printing)
    }

    /// True when the card could be the copy that sold.
    func fits(_ card: OwnedCard) -> Bool {
        if let grader {
            if card.isSlabbed {
                return card.graderRaw?.lowercased() == grader && gradeAgrees(card.gradeLabel)
            }
            // The return was never recorded: the card still says it is out.
            return CardTagIndex.has(ReservedTag.atGrader(grader), on: card)
        }
        let atGrader = ReservedTag.allAtGrader.contains { CardTagIndex.has($0, on: card) }
        guard !card.isSlabbed, !atGrader else { return false }
        if let condition, card.condition != condition { return false }
        if let printing, !card.printing.isEmpty, card.printing.caseInsensitiveCompare(printing) != .orderedSame { return false }
        return true
    }

    /// The numbers must be equal. "Pristine 10" and "Gem Mint 10" are two
    /// grades, but a bare "10" on either side could be both.
    private func gradeAgrees(_ label: String?) -> Bool {
        guard let label, let grade else { return true }
        guard let number = label.firstMatch(of: Self.gradePattern).flatMap({ Decimal(string: String($0.1)) }), number == grade else {
            return false
        }
        guard gradeHasWord, label.contains(where: \.isLetter) else { return true }
        return label.lowercased().contains("pristine") == pristine
    }
}

// MARK: - Catalog

/// Names the catalog product behind each card that sold.
///
/// A TCGplayer row names the set exactly as the catalog does, and the number.
/// An eBay row has only its listing title, so the number, the language, and
/// the name come out of the title.
enum SalesOrderCatalog {
    /// One copy of one line. A line with quantity 2 is two copies, and an eBay
    /// listing of "Froakie 088/086 + Frogadier 089/086" is two different cards.
    struct CopyKey: Hashable, Sendable {
        var orderId: String
        var line: Int
        var copy: Int
    }

    private static let numberPattern = #/(\d+)\s*/\s*(\d+)/#

    static func resolve(_ db: Database, orders: [SalesOrderCSV.Order]) throws -> [CopyKey: Int] {
        let categories = try categoryIds(db)
        var out: [CopyKey: Int] = [:]
        for order in orders {
            for (index, line) in order.lines.enumerated() {
                switch order.channel {
                case .tcgplayer:
                    guard let productId = try tcgplayerProduct(db, line: line, categories: categories) else { continue }
                    for copy in 0..<line.quantity {
                        out[CopyKey(orderId: order.orderId, line: index, copy: copy)] = productId
                    }
                case .ebay:
                    let numbers = line.productName.matches(of: numberPattern).map {
                        CollectorNumber(numberNum: Int($0.1), setTotal: Int($0.2))
                    }
                    for copy in 0..<line.quantity {
                        let number = numbers.count == line.quantity ? numbers[copy] : numbers.first
                        guard let number, let productId = try ebayProduct(db, title: line.productName, number: number) else { continue }
                        out[CopyKey(orderId: order.orderId, line: index, copy: copy)] = productId
                    }
                }
            }
        }
        return out
    }

    /// Category ids by lower-case name: "pokemon japan" is 85.
    static func categoryIds(_ db: Database) throws -> [String: Int] {
        var categories: [String: Int] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT categoryId, name FROM category") {
            let id: Int = row["categoryId"]
            categories[(row["name"] as String).lowercased()] = id
        }
        return categories
    }

    static func tcgplayerProduct(_ db: Database, line: SalesOrderCSV.Line, categories: [String: Int]) throws -> Int? {
        let category = categories[line.productLine.lowercased()]
            ?? (line.productLine.lowercased().contains("japan") ? TCGCategory.pokemonJapan : TCGCategory.pokemon)
        let groups = try Int.fetchAll(db, sql: "SELECT groupId FROM cardSet WHERE name = ? AND categoryId = ?", arguments: [line.setName, category])
        guard !groups.isEmpty else { return nil }
        let inSets = groups.map(String.init).joined(separator: ",")

        // TCGplayer names a variant after the number: "Psyduck - 039/217 (Cosmos
        // Holo)", with the plain "Psyduck" at the same number. So the forms of
        // the name decide one at a time, most specific first: the whole name,
        // the name without its number, then the name before the dash. The last
        // is how "N's Zekrom - 031" finds the plain "N's Zekrom".
        var forms = [NameCleaner.clean(line.productName)]
        if !line.number.isEmpty {
            forms.append(NameCleaner.clean(line.productName.replacingOccurrences(of: " - " + line.number, with: "")))
        }
        if let dash = line.productName.range(of: " - ") {
            forms.append(NameCleaner.clean(String(line.productName[..<dash.lowerBound])))
        }

        if !line.number.isEmpty {
            let numbered = try Row.fetchAll(
                db, sql: "SELECT productId, cleanName FROM product WHERE groupId IN (\(inSets)) AND number = ?",
                arguments: [line.number]
            )
            if numbered.count == 1 { return numbered[0]["productId"] as Int }
            if numbered.count > 1 { return named(numbered, forms: forms) }
        }

        // A stamped print or a promo with no number: the name within the set.
        let inGroup = try Row.fetchAll(db, sql: "SELECT productId, cleanName FROM product WHERE groupId IN (\(inSets))")
        return named(inGroup, forms: forms)
    }

    /// The product that the first matching form of the name names. Nil when no
    /// form matches, or when the first form that matches names several.
    private static func named(_ rows: [Row], forms: [String]) -> Int? {
        for form in forms where !form.isEmpty {
            let hits = rows.filter { ($0["cleanName"] as String) == form }
            if hits.count == 1 { return hits[0]["productId"] as Int }
            if hits.count > 1 { return nil }
        }
        return nil
    }

    /// Pokémon only: every eBay row he has is Pokémon, and a title does not
    /// name its category. Japanese first when the title says so.
    static func ebayProduct(_ db: Database, title: String, number: CollectorNumber) throws -> Int? {
        guard let numberNum = number.numberNum, let setTotal = number.setTotal else { return nil }
        let titleTokens = Set(NameCleaner.clean(title).split(separator: " ").map(String.init))
        let japanese = !titleTokens.isDisjoint(with: ["japanese", "jpn", "jp", "japan"])
        let order = japanese ? [TCGCategory.pokemonJapan, TCGCategory.pokemon] : [TCGCategory.pokemon, TCGCategory.pokemonJapan]

        for category in order {
            let rows = try Row.fetchAll(
                db, sql: "SELECT productId, name FROM product WHERE numberNum = ? AND setTotal = ? AND categoryId = ?",
                arguments: [numberNum, setTotal, category]
            )
            let agreeing = rows.filter { row in
                let base = tokens(baseName(row["name"]))
                return !base.isEmpty && base.isSubset(of: titleTokens)
            }
            if agreeing.count == 1 { return agreeing[0]["productId"] as Int }
            if agreeing.count > 1 {
                let whole = agreeing.filter { tokens($0["name"]).isSubset(of: titleTokens) }
                return whole.count == 1 ? whole[0]["productId"] as Int : nil
            }
        }
        return nil
    }

    /// "Charizard V (Alternate Full Art)" is "Charizard V" in a title.
    private static func baseName(_ name: String) -> String {
        var base = name
        if let dash = base.range(of: " - ") { base = String(base[..<dash.lowerBound]) }
        if let paren = base.range(of: " (") { base = String(base[..<paren.lowerBound]) }
        return base
    }

    private static func tokens(_ text: String) -> Set<String> {
        Set(NameCleaner.clean(text).split(separator: " ").map(String.init))
    }
}
