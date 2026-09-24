import Foundation
import SwiftData

/// Things he has paid for that have not reached him: a preorder, or an order
/// still in the mail.
///
/// The "on order" label is the signal, the way "at PSA" is for a card out at a
/// grader, so the tag chip filters them and the badge row shows them with no
/// extra work. `OwnedCard.expectedArrival` is the optional date beside it.
///
/// His calls, 2026-09-24:
/// - The money counts at once. The purchase is on the books the day he pays.
/// - The card does not count in what he has until it arrives: not in the
///   inventory value, not in the ledger's "What you have", not in the potential.
/// - It cannot be ripped or listed until it arrives. It can be sold.
enum OnOrder {
    /// Within this many days of the expected date, a card is due soon.
    static let soonDays = 3

    static func isOnOrder(_ card: OwnedCard) -> Bool {
        CardTagIndex.has(ReservedTag.onOrder, on: card)
    }

    /// Where a card on order stands against its date.
    enum Due: Equatable {
        /// Not on order.
        case arrived
        /// On order with no date.
        case undated
        case later(Date)
        /// Due today or within `soonDays`.
        case soon(Date)
        /// The date has passed and he has not marked it received.
        case overdue(Date)

        var isOverdue: Bool {
            if case .overdue = self { return true }
            return false
        }
    }

    static func due(_ card: OwnedCard, now: Date = Date(), calendar: Calendar = .current) -> Due {
        guard isOnOrder(card) else { return .arrived }
        guard let expected = card.expectedArrival else { return .undated }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: expected)
        ).day ?? 0
        if days < 0 { return .overdue(expected) }
        if days <= soonDays { return .soon(expected) }
        return .later(expected)
    }

    /// What the inventory page's banner says.
    struct Reminder: Equatable {
        var onOrder = 0
        var soon = 0
        var overdue = 0
    }

    /// Counts copies, the way the rest of inventory does. Sold cards are gone,
    /// so they do not count.
    static func reminder(for cards: [OwnedCard], now: Date = Date(), calendar: Calendar = .current) -> Reminder {
        var r = Reminder()
        for card in cards where card.isCommitted && !CardTagIndex.isSold(card) {
            let quantity = max(1, card.quantity)
            switch due(card, now: now, calendar: calendar) {
            case .arrived: continue
            case .undated, .later: break
            case .soon: r.soon += quantity
            case .overdue: r.overdue += quantity
            }
            r.onOrder += quantity
        }
        return r
    }

    /// Puts cards on order. A nil date leaves any date they already carry, so
    /// marking a stack again does not wipe a date he set on one copy.
    @MainActor
    static func mark(_ cards: [OwnedCard], expected: Date?, context: ModelContext) {
        if let expected {
            for card in cards { card.expectedArrival = expected }
        }
        // `add` saves.
        CardTagEditor(context: context).add(ReservedTag.onOrder, to: cards)
    }

    /// Sets or clears the expected date on cards already on order.
    @MainActor
    static func setExpected(_ date: Date?, on cards: [OwnedCard], context: ModelContext) {
        for card in cards where isOnOrder(card) { card.expectedArrival = date }
        try? context.save()
    }

    /// They arrived. The label and the date go, and from here on they count.
    @MainActor
    static func receive(_ cards: [OwnedCard], context: ModelContext) {
        for card in cards { card.expectedArrival = nil }
        // `remove` saves.
        CardTagEditor(context: context).remove(ReservedTag.onOrder, from: cards)
    }
}
