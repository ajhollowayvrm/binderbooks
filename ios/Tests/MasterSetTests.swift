import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// The fixture's Obsidian Flames (group 100) holds Charmander in two
/// printings, Charizard ex, Pidgeot ex, and one sealed booster pack.
@Suite @MainActor struct MasterSetTests {
    private func contents(_ groupId: Int = 100) throws -> (hits: [SearchHit], prices: [Int: [ProductPrice]]) {
        let queue = try Fixture.make()
        return try queue.read { db in try CatalogSearch.masterSetContents(db, groupId: groupId) }
    }

    private func build(_ owned: [MasterSet.OwnedCopy], groupId: Int = 100) throws -> MasterSet {
        let c = try contents(groupId)
        return MasterSet.build(hits: c.hits, prices: c.prices, owned: owned)
    }

    @Test func everyPrintingIsASlotInCollectorOrderAndSealedIsLeftOut() throws {
        let set = try build([])
        #expect(set.slots.map(\.id) == ["3|Normal", "3|Reverse Holofoil", "1|Holofoil", "9|Holofoil"])
        #expect(set.ownedSlots == 0)
        #expect(set.costToFinishCents == 10 + 40 + 4_500 + 800)
    }

    @Test func aCopyFillsOnlyItsOwnPrinting() throws {
        let set = try build([
            .init(productId: 3, printing: "Reverse Holofoil", quantity: 1),
            .init(productId: 1, printing: "Holofoil", quantity: 2),
        ])
        #expect(set.ownedSlots == 2)
        #expect(set.slots.first { $0.id == "3|Normal" }?.isOwned == false)
        #expect(set.slots.first { $0.id == "1|Holofoil" }?.ownedCount == 2)
        // One copy of each slot, so the second Charizard adds nothing.
        #expect(set.ownedValueCents == 40 + 4_500)
        #expect(set.costToFinishCents == 10 + 800)
    }

    @Test func noPrintingSetFillsASlotOnlyWhenThereIsOneChoice() throws {
        let set = try build([
            .init(productId: 9, printing: "", quantity: 1),
            .init(productId: 3, printing: "", quantity: 1),
        ])
        #expect(set.slots.first { $0.id == "9|Holofoil" }?.isOwned == true)
        // Charmander has two printings. The copy fills neither, and the
        // first slot carries the note.
        let normal = set.slots.first { $0.id == "3|Normal" }
        #expect(normal?.isOwned == false)
        #expect(normal?.unsetPrintingCount == 1)
        #expect(set.slots.first { $0.id == "3|Reverse Holofoil" }?.unsetPrintingCount == 0)
    }

    @Test func aProductWithNoPriceIsOneSlotThatAnyCopyFills() throws {
        // Group 102 holds the priceless code card and a sealed collection.
        let empty = try build([], groupId: 102)
        #expect(empty.slots.map(\.id) == ["5|"])
        #expect(empty.unpricedMissing == 1)
        #expect(empty.costToFinishCents == 0)

        let held = try build([.init(productId: 5, printing: "Normal", quantity: 1)], groupId: 102)
        #expect(held.ownedSlots == 1)
        #expect(held.unpricedMissing == 0)
    }

    @Test func soldLostAndSealedCardsDoNotCount() throws {
        let container = try CollectionStore.container(inMemory: true)
        func card(_ configure: (OwnedCard) -> Void) -> OwnedCard {
            let c = OwnedCard(productId: 1, printing: "Holofoil", condition: CardCondition.nearMint.rawValue, confidence: .manual)
            configure(c)
            container.mainContext.insert(c)
            return c
        }
        // These three he still holds.
        _ = card { _ in }
        _ = card { $0.status = .gradedReturned }
        _ = card { $0.isPersonalCollection = true }
        // These three he does not.
        _ = card { $0.status = .sold }
        _ = card { $0.status = .lost }
        _ = card { $0.isSealedSelf = true }
        let cards = try container.mainContext.fetch(FetchDescriptor<OwnedCard>())

        #expect(MasterSet.ownedCopies(cards).count == 3)
    }
}
