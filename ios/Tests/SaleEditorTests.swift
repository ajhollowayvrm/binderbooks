import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// An order on the books takes new details and new cards after it is saved.
@Suite struct SaleEditorTests {
    @MainActor private func store() throws -> ModelContainer {
        try CollectionStore.container(inMemory: true)
    }

    @MainActor private func card(_ context: ModelContext, basis: Int) -> OwnedCard {
        let card = OwnedCard(productId: 42, printing: "Normal", condition: CardCondition.nearMint.rawValue, confidence: .manual)
        card.acquisitionBasisCents = basis
        context.insert(card)
        return card
    }

    /// $32.00 gross, $4.64 in fees, $7.69 postage, and no cards. The net is $19.67.
    @MainActor private func order(_ context: ModelContext) -> Sale {
        let sale = Sale(channelRaw: "ebay", grossCents: 3_200)
        sale.marketplaceFeesCents = 464
        sale.shippingCostCents = 769
        context.insert(sale)
        return sale
    }

    @MainActor private func attachment(_ card: OwnedCard) -> SaleEditor.Attachment {
        SaleEditor.Attachment(card: card, describedAs: "Charizard", basisCents: SaleEditor.knownBasis(card))
    }

    @Test @MainActor func attachingACardSellsItAndGivesTheOrderAGain() throws {
        let container = try store()
        let context = container.mainContext
        let sale = order(context)
        let charizard = card(context, basis: 1_000)
        try context.save()

        let attached = try SaleEditor.attach([attachment(charizard)], to: sale, context: context)

        #expect(attached == 1)
        #expect(sale.lines.count == 1)
        #expect(sale.lines.first?.card?.id == charizard.id)
        #expect(sale.lines.first?.describedAs == "Charizard")
        #expect(CardTagIndex.isSold(charizard))
        #expect(sale.realizedGainCents == 1_967 - 1_000)
    }

    @Test @MainActor func aCardWithNoCostLeavesTheGainUnknown() throws {
        let container = try store()
        let context = container.mainContext
        let sale = order(context)
        let free = card(context, basis: 0)
        try context.save()

        try SaleEditor.attach([attachment(free)], to: sale, context: context)

        #expect(sale.lines.first?.basisIncomplete == true)
        #expect(sale.realizedGainCents == nil)
    }

    @Test @MainActor func aSoldCardDoesNotJoinASecondOrder() throws {
        let container = try store()
        let context = container.mainContext
        let first = order(context)
        let second = order(context)
        let charizard = card(context, basis: 1_000)
        try context.save()

        try SaleEditor.attach([attachment(charizard), attachment(charizard)], to: first, context: context)
        let again = try SaleEditor.attach([attachment(charizard)], to: second, context: context)

        #expect(first.lines.count == 1)
        #expect(again == 0)
        #expect(second.lines.isEmpty)
    }

    /// The import writes a line that names a card and links none. Linking a
    /// card fills that line, so the order does not show the card twice.
    @Test @MainActor func linkingFillsTheLineTheImportWrote() throws {
        let container = try store()
        let context = container.mainContext
        let sale = order(context)
        let recorded = SaleLine(sale: sale, basisIncomplete: true)
        recorded.describedAs = "Froakie 088/086"
        context.insert(recorded)
        let froakie = card(context, basis: 250)
        try context.save()

        let linked = try SaleEditor.link(recorded, to: attachment(froakie), context: context)

        #expect(linked)
        #expect(sale.lines.count == 1)
        #expect(recorded.card?.id == froakie.id)
        #expect(recorded.describedAs == "Froakie 088/086")
        #expect(CardTagIndex.isSold(froakie))
        #expect(sale.realizedGainCents == 1_967 - 250)
    }

    @Test @MainActor func editingTheGrossKeepsTheEstimateAndEditingTheFeesEndsIt() throws {
        let container = try store()
        let context = container.mainContext
        let sale = order(context)
        sale.costsEstimated = true
        try context.save()

        var details = SaleEditor.Details(sale)
        details.grossCents = 3_500
        details.externalOrderId = " 12-34567-89012 "
        try SaleEditor.apply(details, to: sale, context: context)

        #expect(sale.grossCents == 3_500)
        #expect(sale.externalOrderId == "12-34567-89012")
        #expect(sale.costsEstimated)

        details = SaleEditor.Details(sale)
        details.marketplaceFeesCents = 510
        try SaleEditor.apply(details, to: sale, context: context)

        #expect(sale.marketplaceFeesCents == 510)
        #expect(!sale.costsEstimated)
    }

    @Test @MainActor func aCostTypedOnALineGivesTheOrderAGainAndABlankTakesItAway() throws {
        let container = try store()
        let context = container.mainContext
        let sale = order(context)
        let free = card(context, basis: 0)
        try context.save()
        try SaleEditor.attach([attachment(free)], to: sale, context: context)
        let line = try #require(sale.lines.first)

        try SaleEditor.setCost(700, on: line, context: context)

        #expect(!line.basisIncomplete)
        #expect(sale.realizedGainCents == 1_967 - 700)
        #expect(free.acquisitionBasisCents == 0)

        try SaleEditor.setCost(nil, on: line, context: context)

        #expect(line.basisIncomplete)
        #expect(line.basisCents == 0)
        #expect(sale.realizedGainCents == nil)
    }
}
