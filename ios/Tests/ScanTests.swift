import Foundation
import GRDB
import SwiftData
import Testing
@testable import BinderBooks

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

    /// The Sableye that failed on the phone, at its measured proportions. A
    /// still holds the whole desk, so the name is the tallest line on the card
    /// rather than the highest line in the frame.
    @Test func theTallestLineWinsWhenTheNameIsNotTheHighestThing() {
        let items = [
            item("Sableye", top: 0.278, height: 0.043),
            item("Scratch", top: 0.789, height: 0.032),
            item("Lost Mine", top: 0.877, height: 0.029),
            item("only if you have 10 or more cards in", top: 0.910, height: 0.031),
        ]
        #expect(FrameInterpreter.nameCandidate(items, excluding: nil) == "Sableye")
    }

    /// Text above the card in the photo must not become the card's name.
    @Test func somethingElseOnTheDeskIsNotTheCardName() {
        let items = [
            item("Triumph", top: 0.02, height: 0.012),
            item("caps lock", top: 0.05, height: 0.010),
            item("Sableye", top: 0.278, height: 0.043),
            item("Scratch", top: 0.789, height: 0.032),
        ]
        #expect(FrameInterpreter.nameCandidate(items, excluding: nil) == "Sableye")
    }

    @Test func nameComesFromTheHPLineWhenVisionMergesThem() {
        let items = [
            item("Basic", top: 0.02, height: 0.02),
            item("Articuno HP 110", top: 0.05, height: 0.05),
            item("Frigid Fluttering", top: 0.55, height: 0.05),
            item("Ice Blast 90", top: 0.65, height: 0.05),
            item("161/159", top: 0.93, height: 0.02),
        ]
        #expect(FrameInterpreter.interpret(items).observation.name == "Articuno")
        #expect(FrameInterpreter.nameCandidate([item("Zapdos 110 HP", top: 0.1, height: 0.05)], excluding: nil) == "Zapdos")
    }

    @Test func topmostLineWinsOverAttacksAndLosesItsBareHP() {
        let items = [
            item("Leafeon V 200", top: 0.06, height: 0.05),
            item("Greening Cells", top: 0.5, height: 0.04),
            item("Leaf Blade 90", top: 0.7, height: 0.05),
            item("166/203", top: 0.94, height: 0.02),
        ]
        #expect(FrameInterpreter.interpret(items).observation.name == "Leafeon V")
    }

    @Test func certFromBarcodes() {
        #expect(FrameInterpreter.cert(fromBarcode: "https://www.psacard.com/cert/12345678")?.cert == "12345678")
        #expect(FrameInterpreter.cert(fromBarcode: "https://www.psacard.com/cert/12345678")?.grader == "psa")
        #expect(FrameInterpreter.cert(fromBarcode: "https://www.cgccards.com/certlookup/4321000-001/")?.cert == "4321000")
        #expect(FrameInterpreter.cert(fromBarcode: "87654321")?.cert == "87654321")
        #expect(FrameInterpreter.cert(fromBarcode: "abc") == nil)
    }
}

@Suite struct DuplicateGateTests {
    /// A gate plus a clock, so each step reads as "at t, this number, expect".
    private struct Run {
        var gate = DuplicateGate(absence: 1.5)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        mutating func see(_ number: String?, at seconds: Double) -> Bool {
            gate.shouldAccept(number, at: t0.addingTimeInterval(seconds))
        }
    }

    @Test func acceptsOncePerVisitAfterARepeatedReading() {
        var run = Run()
        let first = run.see(nil, at: 0)
        let second = run.see("114/084", at: 0)
        let third = run.see("114/084", at: 0.1)
        #expect(!first)
        #expect(!second)
        #expect(third)
        // Held still for a while: the ids may churn, the text does not.
        var later = false
        for i in 2...40 { later = later || run.see("114/084", at: Double(i) * 0.1) }
        #expect(!later)
    }

    @Test func aNewVisitStartsAfterTheNumberWasGone() {
        var run = Run()
        _ = run.see("4/102", at: 0)
        let accepted = run.see("4/102", at: 0.1)
        let gone = run.see(nil, at: 1.0)
        let back = run.see("4/102", at: 2.2)
        let backAgain = run.see("4/102", at: 2.3)
        #expect(accepted)
        #expect(!gone)
        #expect(!back)
        #expect(backAgain)
    }

    @Test func aShortGapDoesNotStartANewVisit() {
        var run = Run()
        _ = run.see("4/102", at: 0)
        let accepted = run.see("4/102", at: 0.1)
        let gap = run.see(nil, at: 0.5)
        let back = run.see("4/102", at: 0.8)
        let backAgain = run.see("4/102", at: 0.9)
        #expect(accepted)
        #expect(!gap && !back && !backAgain)
    }

    @Test func differentCardsInterleave() {
        var run = Run()
        _ = run.see("1/102", at: 0)
        let one = run.see("1/102", at: 0.1)
        _ = run.see("2/102", at: 0.2)
        let two = run.see("2/102", at: 0.3)
        let oneAgain = run.see("1/102", at: 0.4)
        #expect(one && two && !oneAgain)
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

    /// A near-exact name that contradicts the number wins, and the result is
    /// uncertain because two signals disagree. Reading "Umbreon" off a card
    /// numbered 164/197 means one of the two is a misread, so the chip must ask
    /// rather than assert.
    @Test func nearExactNameBeatsAContradictingNumber() throws {
        let result = try match(ScanObservation(number: "164/197", name: "Umbreon"))
        #expect(result.productId == 7)
        #expect(result.confidence == .uncertain)
        #expect(result.candidates.map(\.productId).contains(9))
    }

    /// A name the catalog does not hold cannot overrule the number. Glare and
    /// attack text produce readings like this, and the number is still right.
    @Test func unreadableNameKeepsTheNumberMatch() throws {
        let result = try match(ScanObservation(number: "164/197", name: "Zzzzqq"))
        #expect(result.productId == 9)
        #expect(result.confidence == .likely)
    }

    /// His report: a Cyndaquil came back as Combusken. The total read off the
    /// card matched exactly one other card, and the name said otherwise.
    @Test func aMisreadTotalDoesNotReturnTheWrongCard() throws {
        let result = try match(ScanObservation(number: "004/131", name: "Cyndaquil"))
        #expect(result.productId == 11)
        #expect(result.confidence == .uncertain)
        // Combusken stays on the chip, because the number did point at it.
        #expect(result.candidates.map(\.productId).contains(10))
    }

    /// The same number, read correctly off the Combusken, still resolves.
    @Test func theNumberWinsWhenTheNameAgreesWithIt() throws {
        let result = try match(ScanObservation(number: "004/131", name: "Combusken"))
        #expect(result.productId == 10)
        #expect(result.confidence == .certain)
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

    /// The grader charged per card, so the submission's whole cost splits
    /// evenly across its entries and sums back exactly.
    @Test @MainActor func gradingFeesSplitAcrossEntries() throws {
        let container = try CollectionStore.container(inMemory: true)
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let submission = GradingSubmission(graderRaw: "psa", gradingFeesCents: 5_000)
        submission.shipToGraderCents = 1_200
        submission.shipReturnCents = 1_500
        submission.insuranceCents = 301
        context.insert(submission)
        for _ in 0..<3 {
            let card = OwnedCard(productId: 1, printing: "Holofoil", condition: "Near Mint", confidence: .manual)
            context.insert(card)
            context.insert(GradingEntry(submission: submission, card: card))
        }

        Allocation.allocate(submission)

        let fees = submission.entries.map(\.allocatedFeeCents).sorted(by: >)
        #expect(fees == [2_667, 2_667, 2_667])
        #expect(fees.reduce(0, +) == submission.totalCostCents)
    }

    @Test @MainActor func gradingAllocationWithNoEntriesDoesNothing() throws {
        let container = try CollectionStore.container(inMemory: true)
        defer { withExtendedLifetime(container) {} }
        let submission = GradingSubmission(graderRaw: "cgc", gradingFeesCents: 999)
        container.mainContext.insert(submission)
        Allocation.allocate(submission)
        #expect(submission.entries.isEmpty)
    }

    /// A total he set at review comes out of the purchase total first, and the
    /// rest splits over the cards he did not price. This is the test that
    /// catches an allocator overwriting a price he typed.
    @Test @MainActor func aPriceHeSetSurvivesTheAllocator() throws {
        let container = try CollectionStore.container(inMemory: true)
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let purchase = Purchase(vendor: "LGS", itemCostCents: 3_000)
        context.insert(purchase)

        var cards: [OwnedCard] = []
        var items: [PurchaseItem] = []
        for index in 0..<4 {
            let item = PurchaseItem(productId: index + 1)
            item.purchase = purchase
            context.insert(item)
            items.append(item)
            let card = OwnedCard(productId: item.productId, printing: "Normal", condition: "Near Mint", confidence: .certain)
            card.sourceItem = item
            context.insert(card)
            cards.append(card)
        }
        // He priced the first two at $10 each.
        for card in cards.prefix(2) {
            card.acquisitionBasisCents = 1_000
            card.basisIsManual = true
        }

        Allocation.allocate(purchase)
        Allocation.writeCardBases(purchase)

        #expect(cards.map(\.acquisitionBasisCents) == [1_000, 1_000, 500, 500])
        #expect(cards.map(\.basisIsManual) == [true, true, false, false])
        #expect(items.map(\.allocatedCostCents) == [1_000, 1_000, 500, 500])
        #expect(purchase.items.reduce(0) { $0 + $1.allocatedCostCents } == 3_000)
    }

    /// Typing more than the total must not rewrite anything he entered.
    @Test @MainActor func pricesAboveTheTotalLeaveTheSplitAtZero() throws {
        let container = try CollectionStore.container(inMemory: true)
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let purchase = Purchase(vendor: "LGS", itemCostCents: 500)
        context.insert(purchase)

        let priced = PurchaseItem(productId: 1)
        let rest = PurchaseItem(productId: 2)
        var cards: [OwnedCard] = []
        for item in [priced, rest] {
            item.purchase = purchase
            context.insert(item)
            let card = OwnedCard(productId: item.productId, printing: "Normal", condition: "Near Mint", confidence: .certain)
            card.sourceItem = item
            context.insert(card)
            cards.append(card)
        }
        cards[0].acquisitionBasisCents = 2_000
        cards[0].basisIsManual = true

        Allocation.allocate(purchase)
        Allocation.writeCardBases(purchase)

        #expect(cards[0].acquisitionBasisCents == 2_000)
        #expect(cards[1].acquisitionBasisCents == 0)
    }
}

@Suite @MainActor struct ReviewPricingTests {
    private func session() throws -> (ModelContainer, ScanSessionModel, [OwnedCard]) {
        let container = try CollectionStore.container(inMemory: true)
        let context = container.mainContext
        let session = ScanSession()
        context.insert(session)
        var cards: [OwnedCard] = []
        for index in 0..<3 {
            let card = OwnedCard(productId: index + 1, printing: "Normal", condition: "Near Mint", confidence: .certain)
            card.scannedAt = Date(timeIntervalSinceReferenceDate: Double(index))
            card.scanSession = session
            context.insert(card)
            cards.append(card)
        }
        try context.save()
        let model = ScanSessionModel(session: session, context: context, catalog: CatalogController())
        return (container, model, cards)
    }

    /// One total over three cards, split evenly and flagged as his.
    @Test func aTotalSplitsEvenlyOverTheSelection() throws {
        let (container, model, cards) = try session()
        defer { withExtendedLifetime(container) {} }
        model.setBasis(totalCents: 1_000, for: cards)
        #expect(cards.map(\.acquisitionBasisCents) == [334, 333, 333])
        #expect(cards.allSatisfy { $0.basisIsManual })
        // A split figure is derived for any one card, so it must not render as
        // a gain or a loss.
        #expect(cards.allSatisfy { $0.basisIsAllocated })
        #expect(model.manualBasisCents == 1_000)
        #expect(model.pricedCardCount == 3)
    }

    /// A total on one card is that card's real cost, so the gain shows.
    @Test func aTotalOnOneCardIsARealCost() throws {
        let (container, model, cards) = try session()
        defer { withExtendedLifetime(container) {} }
        model.setBasis(totalCents: 2_500, for: [cards[1]])
        #expect(cards[1].acquisitionBasisCents == 2_500)
        #expect(cards[1].basisIsManual)
        #expect(!cards[1].basisIsAllocated)
    }

    @Test func clearingAPriceHandsTheCardBackToTheTotal() throws {
        let (container, model, cards) = try session()
        defer { withExtendedLifetime(container) {} }
        model.setBasis(totalCents: 900, for: cards)
        model.clearBasis(for: [cards[0]])
        #expect(cards[0].acquisitionBasisCents == 0)
        #expect(!cards[0].basisIsManual)
        #expect(!cards[0].basisIsAllocated)
        #expect(model.pricedCardCount == 2)
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
