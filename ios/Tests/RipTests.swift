import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// A rip takes sealed packs out of inventory when its scan commits. It moves
/// no cost and makes no purchase line. Each test keeps its packs in its own
/// `UserDefaults` suite, so no test sees another test's rip.
@Suite @MainActor struct RipTests {
    let container: ModelContainer
    let defaults: UserDefaults

    init() throws {
        container = try CollectionStore.container(inMemory: true)
        defaults = try #require(UserDefaults(suiteName: "RipTests.\(UUID().uuidString)"))
    }

    private var context: ModelContext { container.mainContext }

    @discardableResult
    private func pack(_ productId: Int = 1) -> OwnedCard {
        let card = OwnedCard(productId: productId, printing: "", condition: CardCondition.nearMint.rawValue, confidence: .manual)
        card.isSealedSelf = true
        context.insert(card)
        return card
    }

    private func pull(_ productId: Int, in session: ScanSession) -> OwnedCard {
        let card = OwnedCard(productId: productId, printing: "Normal", condition: CardCondition.nearMint.rawValue, confidence: .certain)
        card.scanSession = session
        context.insert(card)
        return card
    }

    private func ids() throws -> Set<UUID> {
        Set(try context.fetch(FetchDescriptor<OwnedCard>()).map(\.id))
    }

    private func model(_ session: ScanSession) -> ScanSessionModel {
        ScanSessionModel(session: session, context: context, catalog: CatalogController(), defaults: defaults)
    }

    @Test func aRipDeletesThePacksAndKeepsThePulls() throws {
        let purchase = Purchase(vendor: "Walmart", itemCostCents: 4_997)
        context.insert(purchase)
        let line = PurchaseItem(productId: 1, quantity: 3, isSealed: true)
        line.purchase = purchase
        context.insert(line)
        let packs = [pack(), pack(), pack()]
        try context.save()

        let session = try #require(Rip.start(Array(packs.prefix(2)), context: context, defaults: defaults))
        #expect(Rip.isRip(session, defaults: defaults))
        #expect(Set(Rip.packIds(for: session, defaults: defaults)) == Set(packs.prefix(2).map(\.id)))
        let pulls = [pull(10, in: session), pull(11, in: session)]

        model(session).commit()

        let left = try ids()
        #expect(!left.contains(packs[0].id))
        #expect(!left.contains(packs[1].id))
        #expect(left.contains(packs[2].id))
        #expect(pulls.allSatisfy { left.contains($0.id) && $0.isCommitted && $0.sourceItem == nil })
        #expect(try context.fetchCount(FetchDescriptor<PurchaseItem>()) == 1)
        #expect(purchase.landedCostCents == 4_997)
        #expect(!line.isRipped)
        #expect(!Rip.isRip(session, defaults: defaults))
    }

    @Test func aDiscardedRipLeavesThePacksSealed() throws {
        let packs = [pack(), pack()]
        try context.save()

        let session = try #require(Rip.start(packs, context: context, defaults: defaults))
        _ = pull(10, in: session)
        model(session).discard()

        let left = try ids()
        #expect(packs.allSatisfy { left.contains($0.id) && $0.isSealedSelf })
        #expect(left.count == 2)
        #expect(defaults.stringArray(forKey: Rip.key(for: session)) == nil)
    }

    /// A sold pack keeps its card, because its order points at it.
    @Test func aSoldPackNeverRips() throws {
        let sold = pack()
        let open = pack()
        CardTagEditor(context: context).add(ReservedTag.sold, to: [sold])
        try context.save()

        #expect(Rip.rippable([sold, open]).map(\.id) == [open.id])
        #expect(Rip.start([sold], context: context, defaults: defaults) == nil)

        // Sold after the rip started: the commit still leaves it.
        let session = try #require(Rip.start([open], context: context, defaults: defaults))
        CardTagEditor(context: context).add(ReservedTag.sold, to: [open])
        try context.save()
        model(session).commit()

        let left = try ids()
        #expect(left.contains(sold.id))
        #expect(left.contains(open.id))
    }

    @Test func ripWithNothingRemovesThePacks() throws {
        let packs = [pack(), pack()]
        let single = OwnedCard(productId: 5, printing: "Normal", condition: CardCondition.nearMint.rawValue, confidence: .manual)
        context.insert(single)
        try context.save()

        Rip.ripWithNothing(packs + [single], context: context)

        #expect(try ids() == [single.id])
    }

    /// The scanner can close and open again on the same session. The rip must
    /// still know its packs.
    @Test func aRipSurvivesANewSessionModel() throws {
        let packs = [pack(), pack()]
        try context.save()

        let session = try #require(Rip.start(packs, context: context, defaults: defaults))
        _ = model(session)
        let pulled = pull(12, in: session)

        let reopened = model(session)
        reopened.commit()

        let left = try ids()
        #expect(packs.allSatisfy { !left.contains($0.id) })
        #expect(left.contains(pulled.id))
        #expect(session.isCommitted)
    }
}
