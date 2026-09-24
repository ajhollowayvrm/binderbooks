import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// Things he has paid for that have not reached him. The money counts at
/// once; the cards count, rip, and list only once he marks them received.
@Suite @MainActor struct OnOrderTests {
    let container: ModelContainer

    init() throws {
        container = try CollectionStore.container(inMemory: true)
    }

    private var context: ModelContext { container.mainContext }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Noon on 2026-09-24, UTC.
    private let now = Date(timeIntervalSince1970: 1_790_251_200)

    private func days(_ n: Int) -> Date {
        calendar.date(byAdding: .day, value: n, to: now)!
    }

    private func card(_ productId: Int = 1, sealed: Bool = false) -> OwnedCard {
        let card = OwnedCard(productId: productId, printing: "Normal", condition: CardCondition.nearMint.rawValue, confidence: .manual)
        card.isSealedSelf = sealed
        context.insert(card)
        return card
    }

    // MARK: - Marking

    @Test func markingAddsTheLabelAndTheDateAndReceivingTakesBothOff() throws {
        let box = card(sealed: true)
        try context.save()

        OnOrder.mark([box], expected: days(5), context: context)
        #expect(OnOrder.isOnOrder(box))
        #expect(box.expectedArrival == days(5))

        OnOrder.receive([box], context: context)
        #expect(!OnOrder.isOnOrder(box))
        #expect(box.expectedArrival == nil)
        #expect(box.tags.isEmpty)
    }

    /// Marking a stack again with no date keeps a date one copy already had.
    @Test func markingWithNoDateKeepsTheDateACardHas() throws {
        let box = card(sealed: true)
        OnOrder.mark([box], expected: days(5), context: context)
        OnOrder.mark([box], expected: nil, context: context)
        #expect(box.expectedArrival == days(5))
        #expect(box.tags == [ReservedTag.onOrder])
    }

    // MARK: - Due

    @Test func dueReadsTheDateAgainstToday() throws {
        let later = card(1), soon = card(2), today = card(3), late = card(4), undated = card(5), here = card(6)
        OnOrder.mark([later], expected: days(10), context: context)
        OnOrder.mark([soon], expected: days(OnOrder.soonDays), context: context)
        OnOrder.mark([today], expected: now, context: context)
        OnOrder.mark([late], expected: days(-1), context: context)
        OnOrder.mark([undated], expected: nil, context: context)

        #expect(OnOrder.due(later, now: now, calendar: calendar) == .later(days(10)))
        #expect(OnOrder.due(soon, now: now, calendar: calendar) == .soon(days(OnOrder.soonDays)))
        #expect(OnOrder.due(today, now: now, calendar: calendar) == .soon(now))
        #expect(OnOrder.due(late, now: now, calendar: calendar) == .overdue(days(-1)))
        #expect(OnOrder.due(undated, now: now, calendar: calendar) == .undated)
        #expect(OnOrder.due(here, now: now, calendar: calendar) == .arrived)
    }

    /// The banner counts copies, and leaves out what arrived and what sold.
    @Test func theReminderCountsWhatIsStillComing() throws {
        let bulk = card(1)
        bulk.quantity = 3
        let late = card(2)
        let soon = card(3)
        let sold = card(4)
        _ = card(5)
        OnOrder.mark([bulk], expected: days(20), context: context)
        OnOrder.mark([late], expected: days(-2), context: context)
        OnOrder.mark([soon], expected: days(1), context: context)
        OnOrder.mark([sold], expected: days(-9), context: context)
        CardTagEditor(context: context).add(ReservedTag.sold, to: [sold])

        let all = try context.fetch(FetchDescriptor<OwnedCard>())
        let r = OnOrder.reminder(for: all, now: now, calendar: calendar)
        #expect(r == OnOrder.Reminder(onOrder: 5, soon: 1, overdue: 1))
    }

    // MARK: - What it blocks

    @Test func aPackOnOrderDoesNotRip() throws {
        let coming = card(1, sealed: true)
        let here = card(1, sealed: true)
        OnOrder.mark([coming], expected: nil, context: context)

        #expect(Rip.rippable([coming, here]).map(\.id) == [here.id])
        let defaults = try #require(UserDefaults(suiteName: "OnOrderTests.\(UUID().uuidString)"))
        #expect(Rip.start([coming], context: context, defaults: defaults) == nil)
    }

    @Test func aCardOnOrderIsNotListed() throws {
        let single = card(1)
        let hit = SearchHit(productId: 1, groupId: 1, categoryId: 3, name: "Charizard ex", cleanName: "Charizard ex", setName: "Delta Reign", isSealed: false, printingCount: 1)
        #expect(TCGplayerListingExport.skipReason(for: single, hit: hit) == nil)

        OnOrder.mark([single], expected: nil, context: context)
        #expect(TCGplayerListingExport.skipReason(for: single, hit: hit) == .onOrder)
    }

    // MARK: - What it counts

    @Test func theInventorySummaryLeavesOutCardsOnOrder() throws {
        let here = card(1)
        let coming = card(2)
        OnOrder.mark([coming], expected: nil, context: context)

        let model = InventoryModel()
        let summary = model.summary(of: [
            InventoryRow(card: here, hit: nil, marketCents: 500),
            InventoryRow(card: coming, hit: nil, marketCents: 9_000),
        ])
        #expect(summary == InventorySummary(cardCount: 1, marketCents: 500, onOrderCount: 1))
    }

    /// The purchase counts in what he spent the day he pays. The box counts in
    /// what he has once it arrives.
    @Test func theLedgerCountsTheMoneyNowAndTheCardOnArrival() throws {
        let purchase = Purchase(vendor: "Pokémon Center", itemCostCents: 16_999)
        context.insert(purchase)
        let box = card(1, sealed: true)
        OnOrder.mark([box], expected: days(30), context: context)

        let before = LedgerSummary.make(
            purchases: [purchase], grading: [], sales: [], expenses: [],
            held: [box].filter(LedgerSummary.isHeld), marketCents: { _ in 20_000 }
        )
        #expect(before.purchasesCents == 16_999)
        #expect(before.onOrderCount == 1)
        #expect(before.heldCardCount == 0)
        #expect(before.heldAtMarketCents == 0)
        #expect(before.gradedHighCents == 0)

        OnOrder.receive([box], context: context)
        let after = LedgerSummary.make(
            purchases: [purchase], grading: [], sales: [], expenses: [],
            held: [box].filter(LedgerSummary.isHeld), marketCents: { _ in 20_000 }
        )
        #expect(after.onOrderCount == 0)
        #expect(after.heldCardCount == 1)
        #expect(after.heldAtMarketCents == 20_000)
    }

    // MARK: - Intake and export

    @Test func aPurchaseNotHereYetGoesInOnOrder() throws {
        let purchase = Purchase(vendor: "Target", itemCostCents: 5_999)
        context.insert(purchase)
        let line = PurchaseIntake.Line(productId: 10, name: "Delta Reign Elite Trainer Box", setName: "Delta Reign", isSealed: true, quantity: 2)

        let cards = PurchaseIntake.record([line], on: purchase, context: context, onOrder: true, expectedArrival: days(14))
        #expect(cards.count == 2)
        #expect(cards.allSatisfy(OnOrder.isOnOrder))
        #expect(cards.allSatisfy { $0.expectedArrival == days(14) })

        let here = PurchaseIntake.record([line], on: purchase, context: context)
        #expect(!here.contains(where: OnOrder.isOnOrder))
        #expect(here.allSatisfy { $0.expectedArrival == nil })
    }

    @Test func theDateSurvivesTheExportRoundTrip() throws {
        let box = card(1, sealed: true)
        OnOrder.mark([box], expected: days(14), context: context)

        let file = try CollectionExport.decode(try CollectionExport.exportData(context))
        #expect(file.version == 10)

        let target = try CollectionStore.container(inMemory: true)
        _ = try CollectionExport.apply(file, to: target.mainContext, mode: .merge)
        let restored = try #require(try target.mainContext.fetch(FetchDescriptor<OwnedCard>()).first)
        #expect(OnOrder.isOnOrder(restored))
        #expect(restored.expectedArrival == days(14))
    }
}
