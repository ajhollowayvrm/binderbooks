import Foundation
import GRDB
import SwiftData
import Testing
@testable import CardTracker

@Suite struct FrameInterpreterTests {
    private func item(_ text: String, top: CGFloat, height: CGFloat) -> RecognizedText {
        RecognizedText(id: UUID(), transcript: text, top: top, height: height)
    }

    @Test func findsTheNumberAndTheName() {
        let items = [
            item("Mega Zeraora ex", top: 0.05, height: 0.05),
            item("HP 330", top: 0.05, height: 0.04),
            item("Basic", top: 0.02, height: 0.02),
            item("Plasma Fists 120", top: 0.5, height: 0.03),
            item("Illus. 5ban Graphics", top: 0.9, height: 0.015),
            item("114/084", top: 0.93, height: 0.02),
        ]
        let (observation, numberID) = FrameInterpreter.interpret(items)
        #expect(observation.number == "114/084")
        #expect(observation.name == "Mega Zeraora ex")
        #expect(numberID == items[5].id)
    }

    @Test func numberToleratesASpaceAroundTheSlash() {
        #expect(FrameInterpreter.number(in: ["114/ 084"])?.value == "114/084")
        #expect(FrameInterpreter.number(in: ["025 / 102 ★"])?.value == "025/102")
        #expect(FrameInterpreter.number(in: ["SWSH083"])?.value == "SWSH083")
        #expect(FrameInterpreter.number(in: ["BT26-052 C"])?.value == "BT26-052")
        #expect(FrameInterpreter.number(in: ["UE10BT/AOT-1-007"])?.value == "UE10BT/AOT-1-007")
        #expect(FrameInterpreter.number(in: ["001/M-P"])?.value == "001/M-P")
        #expect(FrameInterpreter.number(in: ["HP 120", "Charizard"]) == nil)
    }

    @Test func nameSkipsNoise() {
        let items = [
            item("HP 120", top: 0.05, height: 0.06),
            item("Charizard", top: 0.06, height: 0.05),
            item("Fire Spin 100", top: 0.6, height: 0.05),
        ]
        #expect(FrameInterpreter.nameCandidate(items, excluding: nil) == "Charizard")
    }

    @Test func certFromBarcodes() {
        #expect(FrameInterpreter.cert(fromBarcode: "https://www.psacard.com/cert/12345678")?.cert == "12345678")
        #expect(FrameInterpreter.cert(fromBarcode: "https://www.psacard.com/cert/12345678")?.grader == "psa")
        #expect(FrameInterpreter.cert(fromBarcode: "https://www.cgccards.com/certlookup/4321000-001/")?.cert == "4321000")
        #expect(FrameInterpreter.cert(fromBarcode: "87654321")?.cert == "87654321")
        #expect(FrameInterpreter.cert(fromBarcode: "abc") == nil)
    }
}

@Suite struct SimilarityAndPrintingTests {
    @Test func diceIsTolerantOfOcrMisreads() {
        #expect(Similarity.dice("charizard", "charizard") == 1)
        #expect(Similarity.dice("charlzard", "charizard") > 0.6)
        #expect(Similarity.dice("mega zeraora ex", "mega zeraora ex") == 1)
        #expect(Similarity.dice("mega zeraora", "mega zeraora ex") > 0.8)
        #expect(Similarity.dice("umbreon", "charizard") < 0.2)
    }

    @Test func onePrintingIsAssignedWithoutAGuess() {
        #expect(PrintingRules.choose(available: ["Holofoil"], rarity: "Double Rare", sessionDefault: nil) == .init(printing: "Holofoil", guessed: false))
    }

    @Test func severalPrintingsFollowTheRarityRuleAndAreFlagged() {
        #expect(PrintingRules.choose(available: ["Normal", "Reverse Holofoil"], rarity: "Common", sessionDefault: nil) == .init(printing: "Normal", guessed: true))
        #expect(PrintingRules.choose(available: ["Holofoil", "Reverse Holofoil"], rarity: "Holo Rare", sessionDefault: nil) == .init(printing: "Holofoil", guessed: true))
        #expect(PrintingRules.choose(available: ["Normal", "Holofoil"], rarity: nil, sessionDefault: nil) == .init(printing: "Normal", guessed: true))
    }

    @Test func sessionDefaultWinsWhenAvailable() {
        #expect(PrintingRules.choose(available: ["Normal", "Reverse Holofoil"], rarity: "Common", sessionDefault: "Reverse Holofoil") == .init(printing: "Reverse Holofoil", guessed: false))
        #expect(PrintingRules.choose(available: ["Holofoil"], rarity: "Rare", sessionDefault: "Reverse Holofoil") == .init(printing: "Holofoil", guessed: false))
    }
}

@Suite struct CardMatcherTests {
    private func match(_ observation: ScanObservation, bias: [Int] = [], defaultPrinting: String? = nil) throws -> MatchResult {
        let queue = try Fixture.make()
        return try queue.read { db in
            try CardMatcher.match(db, observation: observation, bias: bias, defaultPrinting: defaultPrinting)
        }
    }

    @Test func uniqueNumberWithAgreeingNameIsCertain() throws {
        let result = try match(ScanObservation(number: "125/197", name: "Charizard ex"))
        #expect(result.productId == 1)
        #expect(result.confidence == .certain)
        #expect(result.printing == "Holofoil")
        #expect(!result.printingGuessed)
    }

    @Test func uniqueNumberWithNoNameIsCertain() throws {
        let result = try match(ScanObservation(number: "164/197"))
        #expect(result.productId == 9)
        #expect(result.confidence == .certain)
    }

    @Test func uniqueNumberWithDisagreeingNameIsLikely() throws {
        let result = try match(ScanObservation(number: "164/197", name: "Umbreon"))
        #expect(result.productId == 9)
        #expect(result.confidence == .likely)
    }

    @Test func guessedPrintingMarksUncertain() throws {
        let result = try match(ScanObservation(number: "026/197", name: "Charmander"))
        #expect(result.productId == 3)
        #expect(result.printingGuessed)
        #expect(result.confidence == .uncertain)
        #expect(result.printing == "Normal")
    }

    @Test func sessionDefaultPrintingKeepsConfidence() throws {
        let result = try match(ScanObservation(number: "026/197", name: "Charmander"), defaultPrinting: "Reverse Holofoil")
        #expect(result.confidence == .certain)
        #expect(result.printing == "Reverse Holofoil")
    }

    @Test func setCodeNumbersMatchDigimon() throws {
        let result = try match(ScanObservation(number: "BT26-052", name: nil))
        #expect(result.productId == 8)
        #expect(result.confidence == .certain)
    }

    @Test func noNumberFallsBackToName() throws {
        let result = try match(ScanObservation(number: nil, name: "Pidgeot ex"))
        #expect(result.productId == 9)
        #expect(result.candidates.first?.productId == 9)
        #expect(result.confidence == .likely)
    }

    @Test func nothingReadableIsUncertainWithNoProduct() throws {
        let result = try match(ScanObservation(number: nil, name: "Zzzzqq"))
        #expect(result.productId == nil)
        #expect(result.confidence == .uncertain)
    }

    @Test func reassignFindsTheNumberInAnotherSet() throws {
        let queue = try Fixture.make()
        let found = try queue.read { db in try CardMatcher.product(db, inGroup: 100, numberNum: 164) }
        #expect(found?.productId == 9)
        let missing = try queue.read { db in try CardMatcher.product(db, inGroup: 101, numberNum: 164) }
        #expect(missing == nil)
    }
}

@Suite struct AllocationTests {
    @Test func equalSplitSumsExactly() {
        #expect(Allocation.splitEqually(100_000, into: 3) == [33_334, 33_333, 33_333])
        #expect(Allocation.splitEqually(497, into: 3) == [166, 166, 165])
        #expect(Allocation.splitEqually(0, into: 4) == [0, 0, 0, 0])
        #expect(Allocation.splitEqually(10, into: 0) == [])
        for total in [1, 7, 99, 19_339, 1_000_001] {
            for count in 1...13 {
                #expect(Allocation.splitEqually(total, into: count).reduce(0, +) == total)
            }
        }
    }

    @Test @MainActor func purchaseAllocationExcludesBulk() throws {
        // Swift frees the container after its last use, and that resets the
        // context under the models. Keep it alive for the whole test.
        let container = try CollectionStore.container(inMemory: true)
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let purchase = Purchase(vendor: "Walmart", itemCostCents: 497)
        context.insert(purchase)

        let hit1 = PurchaseItem(productId: 1)
        let hit2 = PurchaseItem(productId: 2)
        let hit3 = PurchaseItem(productId: 3)
        let bulk = PurchaseItem(productId: 4)
        for item in [hit1, hit2, hit3, bulk] {
            item.purchase = purchase
            context.insert(item)
            let card = OwnedCard(productId: item.productId, printing: "Normal", condition: "Near Mint", confidence: .certain)
            card.isBulk = item === bulk
            card.sourceItem = item
            context.insert(card)
        }

        Allocation.allocate(purchase)
        Allocation.writeCardBases(purchase)

        #expect([hit1, hit2, hit3].map(\.allocatedCostCents) == [166, 166, 165])
        #expect(bulk.allocatedCostCents == 0)
        #expect(hit1.cards.first?.acquisitionBasisCents == 166)
        #expect(hit1.cards.first?.basisIsAllocated == true)
        #expect(bulk.cards.first?.acquisitionBasisCents == 0)
        #expect(purchase.items.reduce(0) { $0 + $1.allocatedCostCents } == 497)
    }
}

@Suite struct ScanSessionModelTests {
    /// Held by the suite so the context outlives every model the tests touch.
    let container: ModelContainer

    init() throws {
        container = try CollectionStore.container(inMemory: true)
    }

    @MainActor
    private func makeModel() throws -> (ScanSessionModel, ModelContext) {
        let context = container.mainContext
        let session = ScanSession()
        context.insert(session)
        let catalog = CatalogController()
        return (ScanSessionModel(session: session, context: context, catalog: catalog), context)
    }

    @Test @MainActor func slabsLandUnidentifiedWithTheirCert() throws {
        let (model, _) = try makeModel()
        model.handle(ScanObservation(certNumber: "12345678", grader: "psa"))
        model.handle(ScanObservation(certNumber: "12345678", grader: "psa"))
        #expect(model.cards.count == 1)
        #expect(model.cards.first?.certNumber == "12345678")
        #expect(model.cards.first?.isIdentified == false)
        #expect(model.cardsNeedingReview.count == 1)
    }

    @Test @MainActor func commitCreatesLinesAllocatesAndMarksTheSession() throws {
        let (model, context) = try makeModel()
        for id in [1, 2, 3] {
            let card = OwnedCard(productId: id, printing: "Holofoil", condition: "Near Mint", confidence: .certain)
            card.scanSession = model.session
            context.insert(card)
        }
        model.duplicateLast()
        #expect(model.cards.count == 4)

        let purchase = Purchase(vendor: "Whatnot", itemCostCents: 19_339)
        context.insert(purchase)
        model.commit(to: purchase)

        #expect(model.session.isCommitted)
        #expect(model.session.purchase === purchase)
        #expect(purchase.items.count == 4)
        #expect(purchase.items.reduce(0) { $0 + $1.allocatedCostCents } == 19_339)
        #expect(model.cards.allSatisfy { $0.isCommitted && $0.basisIsAllocated && $0.sourceItem != nil })
        #expect(model.cards.reduce(0) { $0 + $1.acquisitionBasisCents } == 19_339)
    }

    @Test @MainActor func sessionBiasKeepsTheNewestSetsFirst() {
        let session = ScanSession()
        for id in [100, 101, 100, 102] { session.observe(groupId: id) }
        #expect(session.observedGroupIds == [102, 100, 101])
    }
}
