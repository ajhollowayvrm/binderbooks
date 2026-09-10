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
    private(set) var inFlight = 0
    private(set) var lastError: String?

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
        if let exact = rows.first(where: { $0.subTypeName == card.printing })?.marketCents {
            return exact
        }
        return rows.compactMap(\.marketCents).min()
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
        Task {
            defer { inFlight -= 1 }
            do {
                let result = try await CardMatcher(database: db).match(observation, session: bias, defaultPrinting: defaultPrinting)
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
        copy.scanSession = session
        context.insert(copy)
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

    func setBulk(_ isBulk: Bool, for cards: [OwnedCard]) {
        for card in cards { card.isBulk = isBulk }
        save()
    }

    func confirm(_ card: OwnedCard) {
        card.matchConfidence = .manual
        save()
    }

    func delete(_ cards: [OwnedCard]) {
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

    // MARK: - Commit

    /// Attach the session to a purchase, create one line per card, allocate,
    /// and mark the session committed.
    func commit(to purchase: Purchase) {
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
        session.committedAt = Date()
        save()
    }

    func discard() {
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
    }

    private func save() {
        do {
            try context.save()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
