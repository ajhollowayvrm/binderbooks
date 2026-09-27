import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// The wipe of 2026-09-26 deletes only the raw singles he holds.
@Suite struct SinglesWipeTests {
    @MainActor private func card(_ context: ModelContext, _ tags: [String] = []) -> OwnedCard {
        let card = OwnedCard(productId: 709_971, printing: "Normal", condition: CardCondition.nearMint.rawValue, confidence: .manual)
        card.tags = tags
        context.insert(card)
        return card
    }

    @Test @MainActor func onlyTheHeldRawSinglesGo() throws {
        let container = try CollectionStore.container(inMemory: true)
        let context = container.mainContext

        let purchase = Purchase(vendor: "Card show", itemCostCents: 4_000)
        context.insert(purchase)
        let line = PurchaseItem(productId: 709_971, quantity: 3)
        line.purchase = purchase
        line.allocatedCostCents = 4_000
        context.insert(line)

        let plain = card(context)
        let listed = card(context, [ReservedTag.listed])
        listed.sourceItem = line

        var kept: [OwnedCard] = []
        kept.append(card(context, [ReservedTag.sold]))
        let soldByStatus = card(context)
        soldByStatus.status = .sold
        kept.append(soldByStatus)
        kept.append(card(context, [ReservedTag.atCGC]))
        let atGrader = card(context)
        atGrader.status = .atGrader
        kept.append(atGrader)
        kept.append(card(context, [ReservedTag.lost]))
        let slab = card(context)
        slab.certNumber = "12345678"
        kept.append(slab)
        let sealed = card(context)
        sealed.isSealedSelf = true
        kept.append(sealed)
        let personal = card(context)
        personal.isPersonalCollection = true
        kept.append(personal)

        // A card on the ledger stays, also when nothing else marks it.
        let onSale = card(context)
        let sale = Sale(channelRaw: "tcgplayer", grossCents: 500)
        context.insert(sale)
        context.insert(SaleLine(sale: sale, card: onSale))
        kept.append(onSale)
        let returnedUngraded = card(context)
        let submission = GradingSubmission(graderRaw: "psa")
        context.insert(submission)
        context.insert(GradingEntry(submission: submission, card: returnedUngraded))
        kept.append(returnedUngraded)

        // A card still in an open scan session is not inventory yet.
        let session = ScanSession()
        context.insert(session)
        let pending = card(context)
        pending.scanSession = session
        kept.append(pending)
        try context.save()

        #expect(try SinglesWipe.run(context) == 2)

        let left = Set(try context.fetch(FetchDescriptor<OwnedCard>()).map(\.id))
        #expect(left == Set(kept.map(\.id)))
        #expect(!left.contains(plain.id))
        #expect(purchase.landedCostCents == 4_000)
        #expect(line.allocatedCostCents == 4_000)
        #expect(line.cards.isEmpty)
        #expect(try SinglesWipe.run(context) == 0)
    }
}
