import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// The main page's Singles and Sealed chips, and a card added to a scan by
/// catalog search in place of the camera.
@Suite @MainActor struct CatalogAddAndKindTests {
    private func hit(_ id: Int, sealed: Bool = false) -> SearchHit {
        SearchHit(
            productId: id, groupId: 100, categoryId: 3, name: "P\(id)", cleanName: "p\(id)",
            setName: "SV10: Destined Rivals", isSealed: sealed, printingCount: 1
        )
    }

    @Test func theKindChipsSplitSinglesFromSealed() throws {
        let container = try CollectionStore.container(inMemory: true)
        let context = container.mainContext
        let single = OwnedCard(productId: 1, printing: "Normal", condition: CardCondition.nearMint.rawValue, confidence: .manual)
        // A box added from the plus menu: its self-card.
        let box = OwnedCard(productId: 2, printing: "", condition: CardCondition.nearMint.rawValue, confidence: .manual)
        box.isSealedSelf = true
        // A sealed product the catalog files as sealed, with no self-card flag.
        let pack = OwnedCard(productId: 3, printing: "", condition: CardCondition.nearMint.rawValue, confidence: .manual)
        for card in [single, box, pack] { context.insert(card) }
        try context.save()
        let cards = [single, box, pack]

        let model = InventoryModel()
        model.setTestRows(hits: [1: hit(1), 2: hit(2, sealed: true), 3: hit(3, sealed: true)], prices: [:])

        #expect(Set(model.rows(from: cards).map(\.card.productId)) == [1, 2, 3])
        model.filter.kind = .singles
        #expect(model.rows(from: cards).map(\.card.productId) == [1])
        #expect(model.filter.isActive)
        model.filter.kind = .sealed
        #expect(Set(model.rows(from: cards).map(\.card.productId)) == [2, 3])
    }

    @Test func aCardFromTheCatalogJoinsTheScanAsPicked() async throws {
        let container = try CollectionStore.container(inMemory: true)
        let context = container.mainContext
        let session = ScanSession(defaultCondition: CardCondition.lightlyPlayed.rawValue)
        context.insert(session)
        try context.save()
        let model = ScanSessionModel(session: session, context: context, catalog: CatalogController())

        await model.add(hit(42))
        await model.add(hit(42))

        let cards = session.cards
        #expect(cards.count == 2)
        #expect(cards.allSatisfy { $0.productId == 42 && $0.matchConfidence == .manual })
        #expect(cards.allSatisfy { $0.condition == CardCondition.lightlyPlayed.rawValue && $0.candidateProductIds == [42] })
        #expect(session.observedGroupIds == [100])
        #expect(!session.isCommitted)
    }
}
