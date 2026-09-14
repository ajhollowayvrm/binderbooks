import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// Choose a purchase: cards already in inventory join a purchase already on the
/// books, and take their share of what it cost.
@Suite struct PurchaseLinkTests {
    @MainActor private func store() throws -> ModelContainer {
        try CollectionStore.container(inMemory: true)
    }

    private let bought = Date(timeIntervalSince1970: 1_780_000_000)
    private let earlier = Date(timeIntervalSince1970: 1_779_000_000)

    @MainActor private func card(_ context: ModelContext, cost: Int = 0) -> OwnedCard {
        let card = OwnedCard(productId: 42, printing: "Normal", condition: CardCondition.nearMint.rawValue, confidence: .manual)
        card.acquisitionBasisCents = cost
        card.acquiredAt = earlier
        context.insert(card)
        return card
    }

    @MainActor private func purchase(_ context: ModelContext, cents: Int) -> Purchase {
        let purchase = Purchase(date: bought, vendor: "Gamecraft", itemCostCents: cents)
        context.insert(purchase)
        return purchase
    }

    /// A card on its own line of `purchase`, with its share written.
    @MainActor private func lined(_ context: ModelContext, on purchase: Purchase) throws -> OwnedCard {
        let item = PurchaseItem(productId: 42)
        context.insert(item)
        item.purchase = purchase
        let card = card(context)
        card.sourceItem = item
        card.basisIsAllocated = true
        try context.save()
        Allocation.allocate(purchase)
        Allocation.writeCardBases(purchase)
        try context.save()
        return card
    }

    @Test @MainActor func cardsWithNoPurchaseTakeTheirShare() throws {
        let container = try store()
        let context = container.mainContext
        let target = purchase(context, cents: 3_000)
        let cards = [card(context), card(context), card(context)]
        try context.save()

        let result = try PurchaseLink.link(cards, to: target, context: context)

        #expect(result == PurchaseLink.Result(linked: 3, split: true, filledSaleLines: 0))
        #expect(cards.map(\.acquisitionBasisCents) == [1_000, 1_000, 1_000])
        #expect(cards.allSatisfy { $0.basisIsAllocated && $0.acquiredAt == bought })
        #expect(target.items.count == 3)
    }

    /// A cost already on a card is his price. It leaves the total first.
    @Test @MainActor func aCostAlreadyOnTheCardStays() throws {
        let container = try store()
        let context = container.mainContext
        let target = purchase(context, cents: 3_000)
        let priced = card(context, cost: 1_200)
        let unpriced = card(context)
        try context.save()

        try PurchaseLink.link([priced, unpriced], to: target, context: context)

        #expect(priced.basisIsManual)
        #expect(priced.acquisitionBasisCents == 1_200)
        #expect(unpriced.acquisitionBasisCents == 1_800)
    }

    @Test @MainActor func theOldPurchaseSplitsOverTheCardsLeftOnIt() throws {
        let container = try store()
        let context = container.mainContext
        let old = purchase(context, cents: 1_000)
        let moving = try lined(context, on: old)
        let staying = try lined(context, on: old)
        #expect(staying.acquisitionBasisCents == 500)
        let target = purchase(context, cents: 600)

        try PurchaseLink.link([moving], to: target, context: context)

        #expect(moving.sourceItem?.purchase?.id == target.id)
        #expect(moving.acquisitionBasisCents == 600)
        #expect(staying.acquisitionBasisCents == 1_000)
        #expect(old.items.count == 1)
    }

    /// A scan session can rip from a line. Deleting it, or leaving it behind
    /// empty, breaks the session and the export.
    @Test @MainActor func aCardAloneOnItsLineMovesWithTheLine() throws {
        let container = try store()
        let context = container.mainContext
        let old = purchase(context, cents: 1_000)
        let card = try lined(context, on: old)
        let line = try #require(card.sourceItem)
        let session = ScanSession()
        session.ripTarget = line
        context.insert(session)
        let target = purchase(context, cents: 800)
        try context.save()

        try PurchaseLink.link([card], to: target, context: context)

        #expect(card.sourceItem?.id == line.id)
        #expect(line.purchase?.id == target.id)
        #expect(session.ripTarget?.id == line.id)
        #expect(old.items.isEmpty)
        #expect(try CollectionExport.decode(CollectionExport.exportData(context)).purchaseItems.count == 1)
    }

    /// Two pulls from one pack share a line. The one that moves gets its own.
    @Test @MainActor func aSharedLineStaysWithTheCardsLeftOnIt() throws {
        let container = try store()
        let context = container.mainContext
        let old = purchase(context, cents: 1_000)
        let pack = PurchaseItem(productId: 0, quantity: 1, isSealed: true)
        context.insert(pack)
        pack.purchase = old
        let a = card(context)
        let b = card(context)
        a.sourceItem = pack
        b.sourceItem = pack
        let target = purchase(context, cents: 400)
        try context.save()

        try PurchaseLink.link([a], to: target, context: context)

        #expect(a.sourceItem?.id != pack.id)
        #expect(a.sourceItem?.purchase?.id == target.id)
        #expect(pack.cards.map(\.id) == [b.id])
        #expect(pack.purchase?.id == old.id)
        #expect(a.acquisitionBasisCents == 400)
    }

    /// The seed import wrote real costs and marked none of them. A purchase
    /// holding such a card does not split, and the result says so.
    @Test @MainActor func aCostTheImportWroteBlocksTheSplit() throws {
        let container = try store()
        let context = container.mainContext
        let target = purchase(context, cents: 2_000)
        let imported = try lined(context, on: target)
        imported.basisIsAllocated = false
        imported.acquisitionBasisCents = 800
        let incoming = card(context)
        try context.save()

        let result = try PurchaseLink.link([incoming], to: target, context: context)

        #expect(!result.split)
        #expect(imported.acquisitionBasisCents == 800)
        #expect(incoming.acquisitionBasisCents == 0)
    }

    /// An order that recorded no cost takes the card's new one. A cost the order
    /// already knows does not change.
    @Test @MainActor func aSoldCardFillsOnlyAnUnknownCostOnItsOrder() throws {
        let container = try store()
        let context = container.mainContext
        let target = purchase(context, cents: 1_000)
        let unknown = card(context)
        let known = card(context)
        let sale = Sale(soldAt: bought, channelRaw: "tcgplayer", grossCents: 2_000)
        context.insert(sale)
        let open = SaleLine(sale: sale, card: unknown, basisCents: 0, basisIncomplete: true)
        let settled = SaleLine(sale: sale, card: known, basisCents: 300, basisIncomplete: false)
        context.insert(open)
        context.insert(settled)
        try context.save()

        let result = try PurchaseLink.link([unknown, known], to: target, context: context)

        #expect(result.filledSaleLines == 1)
        #expect(open.basisCents == 500)
        #expect(!open.basisIncomplete)
        #expect(settled.basisCents == 300)
    }

    /// The No purchase chip shows the gap: the cards with no cost to split.
    @Test @MainActor func theNoPurchaseChipShowsOnlyTheCardsWithNone() throws {
        let container = try store()
        let context = container.mainContext
        let target = purchase(context, cents: 1_000)
        let linked = try lined(context, on: target)
        let loose = card(context)
        try context.save()
        let model = InventoryModel()
        let all = [linked, loose]

        #expect(model.rows(from: all).count == 2)
        model.filter.noPurchaseOnly = true
        #expect(model.filter.isActive)
        #expect(model.rows(from: all).map(\.card.id) == [loose.id])

        try PurchaseLink.link([loose], to: target, context: context)
        #expect(model.rows(from: all).isEmpty)
    }

    @Test @MainActor func aCardAlreadyOnThePurchaseDoesNotMove() throws {
        let container = try store()
        let context = container.mainContext
        let target = purchase(context, cents: 1_000)
        let card = try lined(context, on: target)

        let result = try PurchaseLink.link([card], to: target, context: context)

        #expect(result.linked == 0)
        #expect(card.acquisitionBasisCents == 1_000)
    }
}
