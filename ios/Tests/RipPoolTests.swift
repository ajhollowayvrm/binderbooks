import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// Several packs ripped as one rip: the pulls share what all the packs cost,
/// and the packs leave inventory only when the rip finishes.
@Suite struct RipPoolTests {
    private let bought = Date(timeIntervalSince1970: 1_780_000_000)
    private let pack = 700
    private let otherPack = 701

    @MainActor private func store() throws -> ModelContainer {
        try CollectionStore.container(inMemory: true)
    }

    /// A purchase of `count` packs, recorded the way the purchase sheet does.
    @MainActor private func packs(_ context: ModelContext, count: Int, cents: Int, productId: Int? = nil) throws -> (Purchase, [OwnedCard]) {
        let purchase = Purchase(date: bought, vendor: "Target", itemCostCents: cents)
        context.insert(purchase)
        let line = PurchaseIntake.Line(productId: productId ?? pack, name: "Destined Rivals Booster Pack", setName: "Destined Rivals", isSealed: true, quantity: count)
        let cards = PurchaseIntake.record([line], on: purchase, context: context)
        try context.save()
        return (purchase, cards)
    }

    @MainActor private func pull(_ context: ModelContext, productId: Int = 42) -> OwnedCard {
        let card = OwnedCard(productId: productId, printing: "Holofoil", condition: CardCondition.nearMint.rawValue, confidence: .certain)
        context.insert(card)
        return card
    }

    private func basis(_ cards: [OwnedCard]) -> Int {
        cards.reduce(0) { $0 + $1.acquisitionBasisCents }
    }

    @Test @MainActor func elevenPacksRipAsOneAndThePullsShareTheWholeOrder() throws {
        let container = try store()
        let context = container.mainContext
        let (purchase, selfCards) = try packs(context, count: 11, cents: 5_500)
        let line = try #require(selfCards.first?.sourceItem)

        let home = try #require(RipPool.prepare(selfCards, context: context))
        #expect(home.id == line.id)
        #expect(home.quantity == 11)
        #expect(home.ripGroupId == nil)
        #expect(!home.isRipped)

        let pulls = [pull(context), pull(context), pull(context)]
        RipPool.finish(home, pulls: pulls, acquiredAt: purchase.date, context: context)

        #expect(home.isRipped)
        #expect(try context.fetch(FetchDescriptor<OwnedCard>()).filter(\.isSealedSelf).isEmpty)
        #expect(basis(pulls) == 5_500)
        #expect(pulls.allSatisfy { $0.basisIsAllocated && $0.sourceItem?.id == home.id && $0.acquiredAt == bought })

        // A new split of the purchase leaves the rip at the whole order.
        Allocation.allocate(purchase)
        Allocation.writeCardBases(purchase)
        #expect(basis(pulls) == 5_500)
    }

    @Test @MainActor func somePacksCarveALineAndTheRestStaySealed() throws {
        let container = try store()
        let context = container.mainContext
        let (purchase, selfCards) = try packs(context, count: 11, cents: 5_500)
        let line = try #require(selfCards.first?.sourceItem)

        let home = try #require(RipPool.prepare(Array(selfCards.prefix(6)), context: context))
        #expect(home.id != line.id)
        #expect(home.quantity == 6)
        #expect(line.quantity == 5)
        #expect(home.allocatedCostCents + line.allocatedCostCents == 5_500)
        #expect(home.allocatedCostCents == 3_000)

        let pulls = [pull(context)]
        RipPool.finish(home, pulls: pulls, acquiredAt: purchase.date, context: context)

        #expect(pulls[0].acquisitionBasisCents == 3_000)
        #expect(line.cards.filter(\.isSealedSelf).count == 5)
        #expect(!line.isRipped)
    }

    @Test @MainActor func packsFromTwoPurchasesShareOneRip() throws {
        let container = try store()
        let context = container.mainContext
        let (first, sixPacks) = try packs(context, count: 6, cents: 3_000)
        let (second, fivePacks) = try packs(context, count: 5, cents: 2_500)

        let home = try #require(RipPool.prepare(sixPacks + fivePacks, context: context))
        #expect(home.purchase?.id == first.id)
        let group = RipPool.lines(of: home)
        #expect(group.count == 2)
        #expect(group.allSatisfy { $0.ripGroupId != nil && $0.ripGroupId == home.ripGroupId })

        let pulls = [pull(context), pull(context)]
        RipPool.finish(home, pulls: pulls, acquiredAt: first.date, context: context)
        #expect(basis(pulls) == 5_500)
        #expect(group.allSatisfy { $0.isRipped })

        // Each pack's cost stays on its own purchase. A change to the second
        // order reaches the pulls on the first.
        second.itemCostCents = 3_500
        _ = PurchaseEditor.resplitIfSafe(second)
        #expect(basis(pulls) == 6_500)
        #expect(first.items.reduce(0) { $0 + $1.allocatedCostCents } == 3_000)
    }

    @Test @MainActor func twoProductsOnOnePurchaseShareOneRip() throws {
        let container = try store()
        let context = container.mainContext
        let purchase = Purchase(date: bought, vendor: "Target", itemCostCents: 5_000)
        context.insert(purchase)
        let lines = [
            PurchaseIntake.Line(productId: pack, name: "A", setName: "A", isSealed: true, quantity: 3),
            PurchaseIntake.Line(productId: otherPack, name: "B", setName: "B", isSealed: true, quantity: 2),
        ]
        let selfCards = PurchaseIntake.record(lines, on: purchase, context: context)
        try context.save()

        let home = try #require(RipPool.prepare(selfCards, context: context))
        #expect(home.productId == pack)
        #expect(RipPool.lines(of: home).count == 2)

        let pulls = [pull(context), pull(context), pull(context)]
        RipPool.finish(home, pulls: pulls, acquiredAt: bought, context: context)
        #expect(basis(pulls) == 5_000)
    }

    @Test @MainActor func aDiscardedScanLeavesThePacksSealed() throws {
        let container = try store()
        let context = container.mainContext
        let (_, sixPacks) = try packs(context, count: 6, cents: 3_000)
        let (_, fivePacks) = try packs(context, count: 5, cents: 2_500)

        let home = try #require(RipPool.prepare(sixPacks + fivePacks, context: context))
        let group = RipPool.lines(of: home)
        RipPool.release(home, context: context)

        #expect(group.allSatisfy { $0.ripGroupId == nil && !$0.isRipped })
        #expect(try context.fetch(FetchDescriptor<OwnedCard>()).filter(\.isSealedSelf).count == 11)
        #expect(basis(sixPacks + fivePacks) == 5_500)
    }

    @Test @MainActor func aDiscardedPartRipJoinsItsLineAgain() throws {
        let container = try store()
        let context = container.mainContext
        let (purchase, selfCards) = try packs(context, count: 11, cents: 5_500)

        let home = try #require(RipPool.prepare(Array(selfCards.prefix(6)), context: context))
        #expect(purchase.items.count == 2)
        RipPool.release(home, context: context)

        let lines = purchase.items.filter { !$0.isDeleted }
        #expect(lines.count == 1)
        #expect(lines.first?.quantity == 11)
        #expect(lines.first?.allocatedCostCents == 5_500)
        #expect(lines.first?.cards.count == 11)
        #expect(basis(selfCards) == 5_500)
    }

    @Test @MainActor func aSoldPackNeverRips() throws {
        let container = try store()
        let context = container.mainContext
        let (purchase, selfCards) = try packs(context, count: 3, cents: 3_000)
        let sold = selfCards[0]
        sold.tags = [ReservedTag.sold]
        try context.save()

        let home = try #require(RipPool.prepare(selfCards, context: context))
        #expect(home.quantity == 2)
        RipPool.finish(home, pulls: [pull(context)], acquiredAt: purchase.date, context: context)

        #expect(!sold.isDeleted)
        #expect(sold.isSealedSelf)
        #expect(sold.acquisitionBasisCents == 1_000)
    }

    /// His real case: the hit was scanned onto the order as a single before the
    /// packs were ripped.
    @Test @MainActor func aHitRecordedAsPartOfTheBuyMovesIntoTheRip() throws {
        let container = try store()
        let context = container.mainContext
        let (purchase, selfCards) = try packs(context, count: 11, cents: 6_000)

        let hitLine = PurchaseItem(productId: 42)
        hitLine.purchase = purchase
        context.insert(hitLine)
        let hit = pull(context)
        hit.sourceItem = hitLine
        try context.save()
        Allocation.allocate(purchase)
        Allocation.writeCardBases(purchase)
        #expect(hit.acquisitionBasisCents == 500)

        let home = try #require(RipPool.prepare(selfCards, context: context))
        RipPool.finish(home, pulls: [], acquiredAt: bought, context: context)
        let moved = try RipPool.addPulls([hit], to: home, context: context)

        #expect(moved == 1)
        #expect(hit.sourceItem?.id == home.id)
        #expect(purchase.items.count == 1)
        #expect(home.allocatedCostCents == 6_000)
        #expect(hit.acquisitionBasisCents == 6_000)
    }

    @Test @MainActor func bulkPullsDoNotTakeThePacksCostAway() throws {
        let container = try store()
        let context = container.mainContext
        let (purchase, selfCards) = try packs(context, count: 2, cents: 1_000)
        let single = PurchaseItem(productId: 43)
        single.purchase = purchase
        context.insert(single)
        let bought = pull(context, productId: 43)
        bought.sourceItem = single
        try context.save()

        let home = try #require(RipPool.prepare(selfCards, context: context))
        let bulk = pull(context)
        bulk.isBulk = true
        RipPool.finish(home, pulls: [bulk], acquiredAt: self.bought, context: context)

        Allocation.allocate(purchase)
        Allocation.writeCardBases(purchase)
        #expect(home.allocatedCostCents > 0)
        #expect(home.allocatedCostCents + single.allocatedCostCents == 1_000)
        #expect(bulk.acquisitionBasisCents == 0)
    }

    @Test @MainActor func aPricedPullComesOutOfTheCostFirst() throws {
        let container = try store()
        let context = container.mainContext
        let (_, selfCards) = try packs(context, count: 4, cents: 2_000)
        let home = try #require(RipPool.prepare(selfCards, context: context))

        let priced = pull(context)
        priced.acquisitionBasisCents = 1_200
        priced.basisIsManual = true
        let others = [pull(context), pull(context)]
        RipPool.finish(home, pulls: [priced] + others, acquiredAt: bought, context: context)

        #expect(priced.acquisitionBasisCents == 1_200)
        #expect(basis(others) == 800)
    }

    @Test @MainActor func theResultComparesPullsToPacks() throws {
        let container = try store()
        let context = container.mainContext
        let (_, selfCards) = try packs(context, count: 11, cents: 5_500)
        let home = try #require(RipPool.prepare(selfCards, context: context))
        let hit = pull(context)
        let filler = pull(context, productId: 43)
        RipPool.finish(home, pulls: [hit, filler], acquiredAt: bought, context: context)

        let result = RipPool.result(of: RipPool.lines(of: home)) { $0.productId == 42 ? 20_000 : nil }
        #expect(result == RipPool.Result(packs: 11, costCents: 5_500, pulls: 2, valueCents: 20_000, unpriced: 1))
        #expect(result.netCents == 14_500)
    }

    @Test @MainActor func theRipGroupSurvivesExportAndImport() throws {
        let source = try store()
        let context = source.mainContext
        let (_, sixPacks) = try packs(context, count: 6, cents: 3_000)
        let (_, fivePacks) = try packs(context, count: 5, cents: 2_500)
        let home = try #require(RipPool.prepare(sixPacks + fivePacks, context: context))
        RipPool.finish(home, pulls: [pull(context)], acquiredAt: bought, context: context)
        let group = try #require(home.ripGroupId)

        let data = try CollectionExport.exportData(context)
        let file = try CollectionExport.decode(data)
        #expect(file.purchaseItems.filter { $0.ripGroupId == group }.count == 2)

        let target = try store()
        _ = try CollectionExport.apply(file, to: target.mainContext, mode: .merge)
        let items = try target.mainContext.fetch(FetchDescriptor<PurchaseItem>())
        #expect(items.filter { $0.ripGroupId == group }.count == 2)
    }

    /// The ledger used to say "no cards yet" for a purchase whose packs were
    /// ripped with another purchase's, and to put every pull on the other one
    /// with no sign the cost was shared.
    @Test @MainActor func theLedgerNamesASharedRipOnBothPurchases() throws {
        let container = try store()
        let context = container.mainContext
        let (gamecraft, sevenPacks) = try packs(context, count: 6, cents: 16_658)
        let (walmart, onePack) = try packs(context, count: 1, cents: 2_845, productId: otherPack)

        let home = try #require(RipPool.prepare(sevenPacks + onePack, context: context))
        RipPool.finish(home, pulls: [pull(context), pull(context)], acquiredAt: bought, context: context)

        #expect(LedgerEntry.cardCount(gamecraft) == "2 cards · shared rip")
        #expect(LedgerEntry.cardCount(walmart) == "ripped with Target")

        // The amount on each row is still what he paid that vendor.
        let entries = LedgerEntry.entries(purchases: [gamecraft, walmart], grading: [], sales: [])
        #expect(entries.map(\.amountCents).sorted() == [-16_658, -2_845].sorted())

        // The rip's cost is the two purchases together, and the breakdown says
        // which part came from where.
        let group = RipPool.lines(of: home)
        let result = RipPool.result(of: group, market: { _ in nil })
        #expect(result.costCents == 19_503)
        let shares = PurchaseDetailView.costShares(of: group, on: gamecraft)
        #expect(shares.count == 2)
        #expect(shares.first?.name == "This purchase")
        #expect(shares.first?.cents == 16_658)
        #expect(shares.last?.cents == 2_845)
    }
}
