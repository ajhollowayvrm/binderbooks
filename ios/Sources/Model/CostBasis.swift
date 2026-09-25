import Foundation
import SwiftData

/// The day the books start.
///
/// AJ's call, 2026-09-25: BinderBooks manages the card business from this day
/// on, and the debt from before it is written off. The Summary counts only the
/// purchases, grading, sales, and expenses dated on or after the start. The
/// older rows stay in the ledger for reference. Every card he held on the
/// start day costs $0.
///
/// The start lives in `UserDefaults` and travels in the export. See
/// `CollectionExport.File.booksStartedAt`.
enum Books {
    static let startKey = "booksStartedAt"

    /// Nil until the first launch of a build that has the start. With no
    /// start, every row counts.
    static func start(_ defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: startKey) as? Date
    }

    static func setStart(_ date: Date, defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: startKey)
    }

    /// True when a row dated `date` is on the books.
    static func counts(_ date: Date, since start: Date?) -> Bool {
        guard let start else { return true }
        return date >= start
    }

    /// A grading charge is dated by when the cards went out, the same as in
    /// the ledger list. See `LedgerEntry.entries`.
    static func date(of submission: GradingSubmission) -> Date {
        submission.shippedAt ?? submission.returnedAt ?? .distantPast
    }

    /// The fresh start, once: the books start now, and every card costs $0.
    ///
    /// Only a save that worked sets the start, so a failure runs again at the
    /// next launch.
    @MainActor
    static func startFresh(_ context: ModelContext, now: Date = Date(), defaults: UserDefaults = .standard) {
        guard start(defaults) == nil else { return }
        guard let cards = try? context.fetch(FetchDescriptor<OwnedCard>()) else { return }
        CostBasis.zero(cards)
        do {
            try context.save()
            setStart(now, defaults: defaults)
        } catch {}
    }
}

/// What a card cost. All arithmetic is integer cents, and every split sums
/// back to its total exactly.
///
/// A card's cost has two parts:
/// - `OwnedCard.acquisitionBasisCents`, written when the card comes in. A
///   purchase splits its landed cost over its cards by market price. A rip
///   splits what the packs cost over the pulls, by market price. He can type
///   a cost on one card. Then `basisIsManual` is true, and a split does not
///   change that card.
/// - Its share of each grading charge dated on or after the start, split
///   equally over the cards on the submission. This part is not stored. It
///   is read from the submissions, so an edit to a charge changes the cards
///   at once.
///
/// A card with no purchase, such as a card scanned or added by hand, costs
/// $0 until he types a cost.
enum CostBasis {
    // MARK: - Splits

    /// Splits `totalCents` in proportion to `weights`, and the shares sum to
    /// exactly `totalCents`. The cents that rounding leaves go to the largest
    /// remainders, then to the earliest index. Weights that sum to zero split
    /// equally. `totalCents` must not be negative.
    static func splitByWeight(_ totalCents: Int, weights: [Int]) -> [Int] {
        let sum = weights.reduce(0) { $0 + max(0, $1) }
        guard sum > 0 else { return Split.equally(totalCents, into: weights.count) }
        var shares = weights.map { totalCents * max(0, $0) / sum }
        let left = totalCents - shares.reduce(0, +)
        let order = weights.indices.sorted { a, b in
            let ra = totalCents * max(0, weights[a]) % sum
            let rb = totalCents * max(0, weights[b]) % sum
            return ra == rb ? a < b : ra > rb
        }
        for index in order.prefix(max(0, left)) { shares[index] += 1 }
        return shares
    }

    /// The weight of a card in a split: its market price times its count. A
    /// card with no price weighs nothing. When no card has a price, the split
    /// is equal.
    static func weight(_ card: OwnedCard, marketCents: (OwnedCard) -> Int?) -> Int {
        max(0, marketCents(card) ?? 0) * max(1, card.quantity)
    }

    /// A stable order, so the same split gives the same cents to the same card.
    static func ordered(_ cards: [OwnedCard]) -> [OwnedCard] {
        cards.sorted { $0.scannedAt == $1.scannedAt ? $0.id.uuidString < $1.id.uuidString : $0.scannedAt < $1.scannedAt }
    }

    // MARK: - Purchases

    /// Splits the purchase's landed cost over the cards on its lines, by
    /// market price.
    ///
    /// - A card with a typed cost keeps it. Its cost comes off the total
    ///   first.
    /// - A line that was ripped keeps the cost it had at the rip. Its cost
    ///   also comes off the total first, because that money went on to the
    ///   pulls. See `Rip.finish`.
    /// - A purchase dated before the start is off the books, so its cards
    ///   cost $0.
    ///
    /// Typing more than the total leaves the other cards at $0. The split
    /// never changes a figure he typed.
    static func split(_ purchase: Purchase, since start: Date?, marketCents: (OwnedCard) -> Int?) {
        let lines = purchase.items
        let fixed = lines.filter(\.isRipped)
        let open = lines.filter { !$0.isRipped }
        let cards = ordered(open.flatMap(\.cards))

        guard Books.counts(purchase.date, since: start) else {
            for card in cards where !card.basisIsManual {
                card.acquisitionBasisCents = 0
                card.basisIsAllocated = false
            }
            for line in open { line.allocatedCostCents = 0 }
            return
        }

        let typed = cards.filter(\.basisIsManual)
        let splitting = cards.filter { !$0.basisIsManual }
        let taken = typed.reduce(0) { $0 + $1.acquisitionBasisCents }
            + fixed.reduce(0) { $0 + $1.allocatedCostCents }
        let remaining = max(0, purchase.landedCostCents - taken)
        let shares = splitByWeight(remaining, weights: splitting.map { weight($0, marketCents: marketCents) })
        for (card, share) in zip(splitting, shares) {
            card.acquisitionBasisCents = share
            card.basisIsAllocated = true
        }
        for line in open {
            line.allocatedCostCents = line.cards.reduce(0) { $0 + $1.acquisitionBasisCents }
        }
    }

    /// He typed a cost on one card. When the card is on a purchase, the rest
    /// of the purchase splits again around it.
    @MainActor
    static func setTyped(_ cents: Int, on card: OwnedCard, since start: Date?, marketCents: (OwnedCard) -> Int?, context: ModelContext) throws {
        card.acquisitionBasisCents = max(0, cents)
        card.basisIsManual = true
        card.basisIsAllocated = false
        if let purchase = card.sourceItem?.purchase {
            split(purchase, since: start, marketCents: marketCents)
        }
        try context.save()
    }

    /// He cleared the cost he typed. A card on a purchase takes its share of
    /// the split again. A card with no purchase goes back to $0.
    @MainActor
    static func clearTyped(on card: OwnedCard, since start: Date?, marketCents: (OwnedCard) -> Int?, context: ModelContext) throws {
        card.basisIsManual = false
        card.acquisitionBasisCents = 0
        if let purchase = card.sourceItem?.purchase {
            split(purchase, since: start, marketCents: marketCents)
        }
        try context.save()
    }

    // MARK: - Rips

    /// What the packs cost, split over the pulls by market price. Returns the
    /// cost that moved.
    ///
    /// The pulls have no link to the purchase. A later edit to the purchase
    /// total does not reach them, because a ripped line keeps its cost. See
    /// `split`.
    @discardableResult
    static func moveRipCost(from packs: [OwnedCard], to pulls: [OwnedCard], marketCents: (OwnedCard) -> Int?) -> Int {
        let total = packs.reduce(0) { $0 + $1.acquisitionBasisCents }
        for pack in packs { pack.sourceItem?.isRipped = true }
        let receiving = ordered(pulls.filter { !$0.basisIsManual })
        guard total > 0, !receiving.isEmpty else { return 0 }
        let shares = splitByWeight(total, weights: receiving.map { weight($0, marketCents: marketCents) })
        for (card, share) in zip(receiving, shares) {
            card.acquisitionBasisCents += share
            card.basisIsAllocated = true
        }
        return total
    }

    // MARK: - Grading

    /// Each card's share of the grading charges on the books, by card id.
    /// A charge splits equally over the cards on it. A charge with no cards
    /// puts nothing on a card.
    static func gradingShares(_ submissions: [GradingSubmission], since start: Date?) -> [UUID: Int] {
        var out: [UUID: Int] = [:]
        for submission in submissions where Books.counts(Books.date(of: submission), since: start) {
            let entries = submission.entries.sorted { $0.id.uuidString < $1.id.uuidString }
            let shares = Split.equally(submission.totalCostCents, into: entries.count)
            for (entry, share) in zip(entries, shares) {
                guard let id = entry.card?.id else { continue }
                out[id, default: 0] += share
            }
        }
        return out
    }

    // MARK: - Reads

    /// What one card cost: what it came in at, plus its grading.
    static func cost(of card: OwnedCard, grading: [UUID: Int]) -> Int {
        card.acquisitionBasisCents + (grading[card.id] ?? 0)
    }

    /// The fresh start: every card costs $0, and no card holds a typed cost.
    static func zero(_ cards: [OwnedCard]) {
        for card in cards {
            card.acquisitionBasisCents = 0
            card.gradingBasisCents = 0
            card.basisIsAllocated = false
            card.basisIsManual = false
        }
    }
}
