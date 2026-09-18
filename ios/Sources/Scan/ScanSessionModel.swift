import Foundation
import Observation
import SwiftData

/// Drives one scan session: matches observations, persists every card as it
/// lands, serves the squares and the review screen, and commits the batch.
@MainActor
@Observable
final class ScanSessionModel {
    let session: ScanSession
    private let context: ModelContext
    private let catalog: CatalogController

    /// Catalog rows for every product the session touches, by productId.
    private(set) var hits: [Int: SearchHit] = [:]
    private(set) var prices: [Int: [ProductPrice]] = [:]
    /// Chinese cards with no eBay sales on PikaQian. They never get a price.
    private(set) var noSales: Set<Int> = []
    private(set) var inFlight = 0
    private(set) var lastError: String?
    /// Copies already in inventory, by productId, then printing. Read once when
    /// the session opens: nothing commits or sells while he scans.
    private(set) var held: [Int: [String: Int]] = [:]

    init(session: ScanSession, context: ModelContext, catalog: CatalogController) {
        self.session = session
        self.context = context
        self.catalog = catalog
    }

    var cards: [OwnedCard] { session.cardsNewestFirst }
    var cardsNeedingReview: [OwnedCard] { cards.filter { $0.matchConfidence.needsReview || !$0.isIdentified } }

    var sessionTotalCents: Int {
        cards.reduce(0) { $0 + (marketCents(for: $1) ?? 0) }
    }

    func hit(for card: OwnedCard) -> SearchHit? {
        hits[card.productId]
    }

    func availablePrintings(for card: OwnedCard) -> [String] {
        prices[card.productId]?.map(\.subTypeName) ?? []
    }

    /// Market value for the card's printing, else the lowest printing.
    func marketCents(for card: OwnedCard) -> Int? {
        guard let rows = prices[card.productId], !rows.isEmpty else { return nil }
        if let exact = rows.first(where: { $0.subTypeName == card.printing })?.valueCents {
            return exact
        }
        return rows.compactMap(\.valueCents).min()
    }

    /// True when the card has no price because it has no eBay sales, not
    /// because no one priced it yet.
    func hasNoSales(_ card: OwnedCard) -> Bool {
        marketCents(for: card) == nil && noSales.contains(card.productId)
    }

    // MARK: - Copies he already holds

    /// Copies of this card's product in inventory, over every printing.
    func heldCount(for card: OwnedCard) -> Int {
        held[card.productId]?.values.reduce(0, +) ?? 0
    }

    /// Copies of this card's product in inventory, in this card's printing.
    func heldCount(for card: OwnedCard, printing: String) -> Int {
        held[card.productId]?[printing] ?? 0
    }

    /// Copies of this card's product scanned so far in this session.
    func sessionCount(for card: OwnedCard) -> Int {
        cards.filter { $0.productId == card.productId }.reduce(0) { $0 + max(1, $1.quantity) }
    }

    /// One line for the newest card, so he sees the count before he adds another.
    /// "Charizard: 3 in inventory (1 Holofoil) · 2 in this scan"
    func copiesLine(for card: OwnedCard) -> String? {
        guard card.isIdentified else { return nil }
        let name = hit(for: card)?.name ?? card.ocrName ?? "This card"
        let total = heldCount(for: card)
        var line = total == 0 ? "\(name): none in inventory" : "\(name): \(total) in inventory"
        if total > 0, !card.printing.isEmpty {
            let same = heldCount(for: card, printing: card.printing)
            if same != total { line += " (\(same) \(card.printing))" }
        }
        let scanned = sessionCount(for: card)
        if scanned > 1 { line += " · \(scanned) in this scan" }
        return line
    }

    /// Build the artwork index before the first card arrives.
    ///
    /// Nine megabytes of signatures and about a second of work. Paid once when
    /// the session opens rather than on the first card he scans, and skipped
    /// silently when the catalog carries no signatures — the matcher then
    /// works on words alone, the way it always did.
    func loadArtIndex() async {
        await catalog.loadArtIndex()
    }

    func loadHeld() {
        let descriptor = FetchDescriptor<OwnedCard>(predicate: #Predicate { $0.productId > 0 })
        held = Self.heldCounts((try? context.fetch(descriptor)) ?? [])
    }

    /// The inventory's own rule: committed and not sold. This session's cards
    /// are not committed, so they never count twice.
    static func heldCounts(_ cards: [OwnedCard]) -> [Int: [String: Int]] {
        var counts: [Int: [String: Int]] = [:]
        for card in cards where card.isIdentified && card.isCommitted && !card.isSealedSelf && !CardTagIndex.isSold(card) {
            counts[card.productId, default: [:]][card.printing, default: 0] += max(1, card.quantity)
        }
        return counts
    }

    // MARK: - Intake

    func handle(_ observation: ScanObservation) {
        guard !observation.isEmpty else { return }
        if let cert = observation.certNumber {
            insertSlab(cert: cert, grader: observation.grader)
            return
        }
        guard let db = catalog.database else {
            lastError = "The catalog is not open."
            return
        }
        inFlight += 1
        let bias = session.observedGroupIds
        let defaultPrinting = session.defaultPrinting
        let language = session.scanLanguage
        Task {
            defer { inFlight -= 1 }
            do {
                let matcher = CardMatcher(database: db, art: catalog.artIndex)
                let result = try await matcher.match(observation, session: bias, defaultPrinting: defaultPrinting, language: language)
                await insert(result, observation: observation)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Debug builds feed typed text through the same path: "Mega Zeraora ex 114/084".
    func simulate(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var observation = ScanObservation()
        if let found = FrameInterpreter.number(in: [trimmed]) {
            observation.number = found.value
            let name = trimmed.replacingOccurrences(of: found.value, with: "").trimmingCharacters(in: .whitespaces)
            observation.name = name.isEmpty ? nil : name
        } else {
            observation.name = trimmed
        }
        observation.sawJapaneseText = FrameInterpreter.isJapanese(trimmed)
        handle(observation)
    }

    private func insert(_ result: MatchResult, observation: ScanObservation) async {
        for hit in result.candidates {
            hits[hit.productId] = hit
        }
        let card = OwnedCard(
            productId: result.productId ?? 0,
            printing: result.printing,
            condition: session.defaultCondition,
            confidence: result.confidence
        )
        card.ocrName = observation.name
        card.ocrNumber = observation.number
        card.candidateProductIds = result.candidates.map(\.productId)
        card.scanSession = session
        context.insert(card)
        // Only a Chinese session takes a photo, for the card's eBay listing.
        if let photo = observation.photoJPEG {
            try? CardPhotoStore.save(photo, for: card.id)
        }
        if let hit = result.hit, result.confidence <= .likely {
            session.observe(groupId: hit.groupId)
        }
        save()
        await loadPrices(for: result.candidates.map(\.productId))
    }

    private func insertSlab(cert: String, grader: String?) {
        if cards.contains(where: { $0.certNumber == cert }) { return }
        let card = OwnedCard(productId: 0, printing: "", condition: session.defaultCondition, confidence: .uncertain)
        card.certNumber = cert
        card.graderRaw = grader
        card.scanSession = session
        context.insert(card)
        save()
    }

    /// Logs the newest card again. For the copies he really does own.
    func duplicateLast() {
        guard let last = cards.first else { return }
        let copy = OwnedCard(productId: last.productId, printing: last.printing, condition: last.condition, confidence: last.matchConfidence)
        copy.ocrName = last.ocrName
        copy.ocrNumber = last.ocrNumber
        copy.candidateProductIds = last.candidateProductIds
        copy.isBulk = last.isBulk
        copy.tags = last.tags
        copy.scanSession = session
        context.insert(copy)
        CardPhotoStore.copy(from: last.id, to: copy.id)
        save()
    }

    // MARK: - Corrections

    func assign(_ card: OwnedCard, to hit: SearchHit) {
        hits[hit.productId] = hit
        card.productId = hit.productId
        card.matchConfidence = .manual
        if !card.candidateProductIds.contains(hit.productId) {
            card.candidateProductIds.insert(hit.productId, at: 0)
        }
        session.observe(groupId: hit.groupId)
        save()
        Task {
            await loadPrices(for: [hit.productId])
            let available = availablePrintings(for: card)
            if !available.contains(card.printing) {
                card.printing = PrintingRules.choose(available: available, rarity: hit.rarity, sessionDefault: session.defaultPrinting).printing
                save()
            }
        }
    }

    func setPrinting(_ printing: String, for cards: [OwnedCard]) {
        for card in cards {
            card.printing = printing
            if card.matchConfidence == .uncertain, card.isIdentified, card.candidateProductIds.count <= 1 {
                card.matchConfidence = .manual
            }
        }
        save()
    }

    func setCondition(_ condition: String, for cards: [OwnedCard]) {
        for card in cards { card.condition = condition }
        save()
    }

    /// Splits one total evenly over the given cards and marks the basis as his.
    /// A split over several cards is still a derived figure for any one card, so
    /// it stays flagged as allocated and never renders as a gain or a loss. A
    /// total set on one card is that card's real cost.
    func setBasis(totalCents: Int, for cards: [OwnedCard]) {
        let tracked = cards.sorted { $0.scannedAt < $1.scannedAt }
        guard !tracked.isEmpty else { return }
        let shares = Allocation.splitEqually(totalCents, into: tracked.count)
        for (card, share) in zip(tracked, shares) {
            card.acquisitionBasisCents = share
            card.basisIsManual = true
            card.basisIsAllocated = tracked.count > 1
        }
        save()
    }

    /// Clears a price he set, so the purchase total covers the card again.
    func clearBasis(for cards: [OwnedCard]) {
        for card in cards {
            card.acquisitionBasisCents = 0
            card.basisIsManual = false
            card.basisIsAllocated = false
        }
        save()
    }

    /// What he has priced himself. The commit sheet subtracts it from the total.
    var manualBasisCents: Int {
        cards.filter(\.basisIsManual).reduce(0) { $0 + $1.acquisitionBasisCents }
    }

    var pricedCardCount: Int { cards.filter(\.basisIsManual).count }

    func setBulk(_ isBulk: Bool, for cards: [OwnedCard]) {
        for card in cards { card.isBulk = isBulk }
        save()
    }

    func confirm(_ card: OwnedCard) {
        card.matchConfidence = .manual
        save()
    }

    func delete(_ cards: [OwnedCard]) {
        CardPhotoStore.remove(cards.map(\.id))
        for card in cards { context.delete(card) }
        save()
    }

    /// Move a run of cards to another set by their numbers. A card whose number
    /// is not in that set stays as it was and is reported back.
    func reassign(_ cards: [OwnedCard], toGroup groupId: Int) async -> [OwnedCard] {
        guard let db = catalog.database else { return cards }
        var missed: [OwnedCard] = []
        for card in cards {
            let numberNum = hits[card.productId]?.numberNum ?? CollectorNumber.parse(card.ocrNumber).numberNum
            guard let numberNum else { missed.append(card); continue }
            do {
                let found = try await db.asyncRead { db in try CardMatcher.product(db, inGroup: groupId, numberNum: numberNum) }
                if let found {
                    assign(card, to: found)
                } else {
                    missed.append(card)
                }
            } catch {
                missed.append(card)
            }
        }
        return missed
    }

    // MARK: - Session settings

    func setDefaultCondition(_ condition: String) {
        session.defaultCondition = condition
        save()
    }

    func setDefaultPrinting(_ printing: String?) {
        session.defaultPrinting = printing
        save()
    }

    /// Which catalogue this run is scanning. Set it before the cards go through.
    func setLanguage(_ language: ScanLanguage) {
        session.language = language.rawValue
        save()
    }

    // MARK: - Commit

    /// Attach the session to a purchase and mark it committed. A generic
    /// session gets one new line per card, and the whole purchase reallocates.
    /// A rip session's cards join the box's own line instead: its cost is
    /// already fixed, so only that line's cards need their basis rewritten.
    ///
    /// The purchase is optional. He can log cards he never paid for, or cards
    /// whose cost he does not want to record yet, and the ledger stays empty.
    /// Those cards keep only the cost he set at review, if he set one.
    func commit(to purchase: Purchase?) {
        if let target = session.ripTarget {
            // The packs leave inventory here, not when the rip started. Every
            // line ripped with this one goes too. See `RipPool`.
            let owner = purchase ?? target.purchase
            RipPool.finish(target, pulls: cards, acquiredAt: owner?.date ?? Date(), context: context)
            session.purchase = owner
        } else if let purchase {
            for card in cards where card.sourceItem == nil {
                let item = PurchaseItem(productId: card.productId, quantity: 1, isSealed: false)
                item.purchase = purchase
                context.insert(item)
                card.sourceItem = item
                card.acquiredAt = purchase.date
            }
            Allocation.allocate(purchase)
            Allocation.writeCardBases(purchase)
            session.purchase = purchase
        }
        session.committedAt = Date()
        save()
    }

    func discard() {
        // A rip that never committed leaves the packs sealed, as they were.
        if let target = session.ripTarget { RipPool.release(target, context: context) }
        // The cascade deletes the cards. Their photos are files, so they go here.
        CardPhotoStore.remove(session.cards.map(\.id))
        context.delete(session)
        save()
    }

    // MARK: - Catalog rows

    func loadRows() async {
        let ids = Array(Set(cards.flatMap { [$0.productId] + $0.candidateProductIds }.filter { $0 > 0 }))
        let missing = ids.filter { hits[$0] == nil }
        guard let db = catalog.database else { return }
        if !missing.isEmpty, let rows = try? await CatalogSearch(database: db).hits(ids: missing) {
            for row in rows { hits[row.productId] = row }
        }
        await loadPrices(for: ids)
    }

    private func loadPrices(for ids: [Int]) async {
        let missing = ids.filter { $0 > 0 && prices[$0] == nil }
        guard !missing.isEmpty, let db = catalog.database else { return }
        if let rows = try? await CatalogSearch(database: db).prices(for: missing) {
            for id in missing { prices[id] = rows[id] ?? [] }
        }
        if let none = try? await db.asyncRead({ try ChineseCatalog.cardsWithNoSales($0, among: missing) }) {
            noSales.formUnion(none)
        }
    }

    private func save() {
        do {
            try context.save()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
