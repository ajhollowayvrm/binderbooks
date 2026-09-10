import Foundation
import SwiftData
import Testing
@testable import BinderBooks

/// Three committed cards and one open-session card, with catalog rows attached.
@MainActor
private struct TagFixture {
    let container: ModelContainer
    let model = InventoryModel()
    let charizard: OwnedCard
    let umbreon: OwnedCard
    let slab: OwnedCard
    let uncommitted: OwnedCard

    init() throws {
        container = try CollectionStore.container(inMemory: true)
        let context = container.mainContext

        charizard = OwnedCard(productId: 1, printing: "Holofoil", condition: "Near Mint", confidence: .certain)
        charizard.ocrName = "Charizard"
        charizard.ocrNumber = "4/102"
        context.insert(charizard)

        umbreon = OwnedCard(productId: 2, printing: "Normal", condition: "Lightly Played", confidence: .certain)
        context.insert(umbreon)

        slab = OwnedCard(productId: 3, printing: "Holofoil", condition: "Near Mint", confidence: .manual)
        slab.certNumber = "12345678"
        slab.graderRaw = "psa"
        context.insert(slab)

        let session = ScanSession()
        context.insert(session)
        uncommitted = OwnedCard(productId: 1, printing: "Normal", condition: "Near Mint", confidence: .likely)
        uncommitted.scanSession = session
        context.insert(uncommitted)

        try context.save()

        model.setTestRows(
            hits: [
                1: SearchHit(
                    productId: 1, groupId: 100, categoryId: 3, name: "Charizard", cleanName: "charizard",
                    setName: "Base Set", number: "4/102", numberNum: 4, setTotal: 102, rarity: "Holo Rare",
                    isSealed: false, printingCount: 2
                ),
                2: SearchHit(
                    productId: 2, groupId: 103, categoryId: 85, name: "Umbreon", cleanName: "umbreon",
                    setName: "Storm Emeralda", number: "020/076", numberNum: 20, setTotal: 76,
                    isSealed: false, printingCount: 1
                ),
                3: SearchHit(
                    productId: 3, groupId: 100, categoryId: 3, name: "Pidgeot ex", cleanName: "pidgeot ex",
                    setName: "Obsidian Flames", number: "164/197", numberNum: 164, setTotal: 197,
                    isSealed: false, printingCount: 1
                ),
            ],
            prices: [:]
        )
    }

    var cards: [OwnedCard] {
        (try? container.mainContext.fetch(FetchDescriptor<OwnedCard>())) ?? []
    }

    var editor: CardTagEditor { CardTagEditor(context: container.mainContext) }

    func ids(_ query: String) -> [Int] {
        model.rows(from: cards, query: query).map(\.card.productId)
    }
}

@Suite struct TagKeyTests {
    @Test func foldsCaseAndSpaceButNotPunctuation() {
        #expect(TagKey.of("For Sale ") == TagKey.of("for  sale"))
        #expect(TagKey.of("Pokémon") == TagKey.of("pokemon"))
        // A label is his own text. `NameCleaner` would merge these two, and it
        // must never be used on a tag.
        #expect(TagKey.of("binder-3") != TagKey.of("binder 3"))
        #expect(TagKey.display("  binder   3 ") == "binder 3")
        #expect(!TagKey.isValid("   "))
    }
}

@Suite @MainActor struct CardTagEditorTests {
    @Test func addMergesAndKeepsTheFirstDisplayForm() throws {
        let f = try TagFixture()
        f.editor.add("for sale", to: [f.charizard])
        f.editor.add("FOR SALE", to: [f.charizard])
        #expect(f.charizard.tags == ["for sale"])
    }

    /// Catches an assign-instead-of-merge, which would wipe every other label
    /// across thirty cards at once.
    @Test func bulkAddKeepsExistingTags() throws {
        let f = try TagFixture()
        f.editor.add("PSA queue", to: [f.slab])
        f.editor.add("binder 3", to: [f.slab, f.charizard])
        #expect(f.slab.tags == ["binder 3", "PSA queue"])
        #expect(f.charizard.tags == ["binder 3"])
    }

    @Test func toggleRemovesWhenEveryCardHasIt() throws {
        let f = try TagFixture()
        f.editor.add("trade night", to: [f.charizard, f.umbreon])
        f.editor.toggle("trade night", on: [f.charizard, f.umbreon])
        #expect(f.charizard.tags.isEmpty)
        // A partial hold adds to the rest instead of removing.
        f.editor.add("keep", to: [f.charizard])
        f.editor.toggle("keep", on: [f.charizard, f.umbreon])
        #expect(f.umbreon.tags == ["keep"])
    }

    @Test func renameRewritesEveryCard() throws {
        let f = try TagFixture()
        f.editor.add("for sale", to: [f.charizard, f.umbreon, f.slab])
        f.editor.rename("FOR SALE", to: "For sale now", in: f.cards)
        #expect(f.cards.allSatisfy { !CardTagIndex.has("for sale", on: $0) })
        #expect(f.charizard.tags == ["For sale now"])
        #expect(f.slab.tags == ["For sale now"])
    }

    /// Catches a stored or cached label list.
    @Test func suggestionsDropADeletedCard() throws {
        let f = try TagFixture()
        f.editor.add("PSA queue", to: [f.slab])
        f.editor.add("binder 3", to: [f.slab, f.charizard])
        #expect(CardTagIndex.uses(in: f.cards).map(\.label) == ["binder 3", "PSA queue"])
        f.container.mainContext.delete(f.slab)
        try f.container.mainContext.save()
        let uses = CardTagIndex.uses(in: f.cards)
        #expect(uses.map(\.label) == ["binder 3"])
        #expect(uses.first?.count == 1)
    }

    /// Two stores that hold the same labels must export the same bytes.
    @Test func tagsSortByKey() throws {
        let f = try TagFixture()
        f.editor.add("zebra", to: [f.charizard])
        f.editor.add("Alpha", to: [f.charizard])
        f.editor.add("middle", to: [f.charizard])
        #expect(f.charizard.tags == ["Alpha", "middle", "zebra"])
    }

    @Test func statusBackfillWritesTheReservedLabelOnce() throws {
        let f = try TagFixture()
        f.charizard.statusRaw = CardStatus.listed.rawValue
        f.slab.statusRaw = CardStatus.atGrader.rawValue
        try f.container.mainContext.save()
        let defaults = UserDefaults(suiteName: "tagtests-\(UUID().uuidString)")!

        StatusTagBackfill.run(f.container.mainContext, defaults: defaults)
        #expect(f.charizard.tags == [ReservedTag.listed])
        #expect(f.slab.tags == [ReservedTag.atGrader])
        #expect(f.umbreon.tags.isEmpty)

        // A second run must not repeat, so a label he removed stays removed.
        f.editor.remove(ReservedTag.listed, from: [f.charizard])
        StatusTagBackfill.run(f.container.mainContext, defaults: defaults)
        #expect(f.charizard.tags.isEmpty)
    }
}

@Suite @MainActor struct OwnedCardSearchTests {
    @Test func emptyQueryReturnsEveryCommittedCard() throws {
        let f = try TagFixture()
        #expect(Set(f.ids("")) == [1, 2, 3])
    }

    @Test func matchesTheCatalogNameAndSet() throws {
        let f = try TagFixture()
        #expect(f.ids("charizard") == [1])
        #expect(f.ids("obsidian") == [3])
        // Tokens in any order, and diacritics fold.
        #expect(f.ids("ex pidgeot") == [3])
    }

    @Test func matchesACollectorNumber() throws {
        let f = try TagFixture()
        #expect(f.ids("4/102") == [1])
        #expect(f.ids("020/076") == [2])
        #expect(f.ids("164/197") == [3])
    }

    @Test func matchesAPartialCertNumber() throws {
        let f = try TagFixture()
        #expect(f.ids("345678") == [3])
        #expect(f.ids("psa") == [3])
    }

    /// The whole point of his request: a label he typed reaches the one field.
    @Test func matchesATag() throws {
        let f = try TagFixture()
        f.editor.add("binder 3", to: [f.umbreon])
        f.model.invalidateHaystacks()
        #expect(f.ids("binder") == [2])
        #expect(f.ids("binder 3") == [2])
    }

    @Test func uncommittedCardsStayOutOfEveryQuery() throws {
        let f = try TagFixture()
        // The open-session card is also productId 1, so a name query must
        // still answer with one row, not two.
        #expect(f.cards.count == 4)
        #expect(f.ids("charizard") == [1])
        #expect(f.model.rows(from: f.cards).count == 3)
    }

    @Test func aChipFilterAndAQueryBothApply() throws {
        let f = try TagFixture()
        f.model.filter.slabsOnly = true
        #expect(f.ids("") == [3])
        #expect(f.ids("charizard").isEmpty)
        // The search sections ignore the chips on the inventory page.
        #expect(f.model.rows(from: f.cards, query: "charizard", applyFilter: false).count == 1)
    }

    @Test func aTagFilterNarrows() throws {
        let f = try TagFixture()
        f.editor.add("for sale", to: [f.umbreon, f.slab])
        f.model.filter.tagKeys = [TagKey.of("FOR SALE")]
        #expect(Set(f.ids("")) == [2, 3])
        #expect(f.model.filter.isActive)
    }

    /// The Clear button on the inventory page must not wipe the header's field.
    @Test func theQueryIsNotPartOfTheChipState() throws {
        var filter = InventoryFilter()
        #expect(!filter.isActive)
        filter.tagKeys = ["x"]
        #expect(filter.isActive)
    }

    @Test func anUnidentifiedCardStillMatchesItsScannedText() throws {
        let f = try TagFixture()
        let orphan = OwnedCard(productId: 0, printing: "", condition: "Near Mint", confidence: .uncertain)
        orphan.ocrName = "Blastoise"
        orphan.ocrNumber = "009/102"
        f.container.mainContext.insert(orphan)
        try f.container.mainContext.save()
        f.model.invalidateHaystacks()
        #expect(f.model.rows(from: f.cards, query: "blastoise").count == 1)
        #expect(f.model.rows(from: f.cards, query: "009/102").count == 1)
    }
}
