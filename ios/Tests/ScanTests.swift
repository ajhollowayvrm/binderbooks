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

    @Test func japaneseScriptIsReported() {
        let items = [
            item("ブラッキー", top: 0.05, height: 0.05),
            item("020/076", top: 0.93, height: 0.02),
        ]
        let (observation, _) = FrameInterpreter.interpret(items)
        #expect(observation.sawJapaneseText)
        #expect(observation.number == "020/076")
        #expect(!FrameInterpreter.interpret([item("Charizard", top: 0.05, height: 0.05)]).observation.sawJapaneseText)
    }

    @Test func certFromBarcodes() {
        #expect(FrameInterpreter.cert(fromBarcode: "https://www.psacard.com/cert/12345678")?.cert == "12345678")
        #expect(FrameInterpreter.cert(fromBarcode: "https://www.psacard.com/cert/12345678")?.grader == "psa")
        #expect(FrameInterpreter.cert(fromBarcode: "https://www.cgccards.com/certlookup/4321000-001/")?.cert == "4321000")
        #expect(FrameInterpreter.cert(fromBarcode: "87654321")?.cert == "87654321")
        #expect(FrameInterpreter.cert(fromBarcode: "abc") == nil)
    }
}

// `DuplicateGateTests` moved to `CardIdentityGateTests.swift` on 2026-09-18,
// with the gate it covered. Every case it held is kept there.

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
    private func match(
        _ observation: ScanObservation,
        bias: [Int] = [],
        defaultPrinting: String? = nil,
        language: ScanLanguage? = nil,
        preferred: [Int] = []
    ) throws -> MatchResult {
        let queue = try Fixture.make()
        return try queue.read { db in
            try CardMatcher.match(
                db, observation: observation, bias: bias, defaultPrinting: defaultPrinting,
                language: language, preferred: preferred
            )
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

    /// His report: the scan did badly on the pattern variants. Black Bolt
    /// prints Snivy three times at 001/086, and all three print the same name,
    /// so the plain card won the name every time and looked certain doing it.
    /// Only the artwork differs, and no reading of the text can see artwork.
    @Test func patternVariantsAskInsteadOfAssertingThePlainCard() throws {
        let result = try match(ScanObservation(number: "001/086", name: "Snivy"))
        #expect(result.confidence == .uncertain)
        // The whole family leads the chip, so the answer is one tap away.
        #expect(Set(result.candidates.prefix(3).map(\.productId)) == [13, 14, 15])
    }

    /// A card with no variant sibling is untouched by the rule.
    @Test func aCardPrintedOnceStaysCertain() throws {
        let result = try match(ScanObservation(number: "125/197", name: "Charizard ex"))
        #expect(result.confidence == .certain)
    }

    /// His report: the scan did badly on Japanese cards. The catalog files a
    /// Japanese card under its English name, so the name on the card can never
    /// agree, and the disagreement threw the match away. The script itself says
    /// the card is Japanese, and 020/076 is one card in that catalogue and
    /// another card in the English one.
    @Test func japaneseScriptKeepsTheMatchInTheJapaneseCatalogue() throws {
        var observation = ScanObservation(number: "020/076", name: "ブラッキー")
        observation.sawJapaneseText = true
        let result = try match(observation)
        #expect(result.productId == 7)
        #expect(result.confidence == .certain)
    }

    /// The rule runs one way only. Glare can hide every kana on the card, and
    /// then the number is all that is left, so a frame with no Japanese in it
    /// must not rule the Japanese catalogue out.
    @Test func noJapaneseScriptStillOffersTheJapaneseCard() throws {
        let result = try match(ScanObservation(number: "020/076"))
        #expect(result.confidence == .uncertain)
        #expect(Set(result.candidates.map(\.productId)) == [7, 16])
    }

    /// What he set on the session decides, and it decides both ways. This is
    /// the failure he reported on an English Dedenne: Vision read a kana out of
    /// the foil, the guess sent the match into the Japanese catalogue, and the
    /// English card was never among the candidates. A stated language cannot be
    /// overruled by a hallucinated one.
    @Test func aStatedEnglishSessionKeepsTheEnglishCard() throws {
        var observation = ScanObservation(number: "020/076")
        observation.sawJapaneseText = true
        let result = try match(observation, language: .english)
        #expect(result.productId == 16)
        #expect(!result.candidates.contains { $0.categoryId == TCGCategory.pokemonJapan })
    }

    /// And the other way: he says Japanese, so the English card carrying the
    /// same number is not the answer, whether or not a kana survived the glare.
    @Test func aStatedJapaneseSessionKeepsTheJapaneseCard() throws {
        let result = try match(ScanObservation(number: "020/076"), language: .japanese)
        #expect(result.productId == 7)
        #expect(result.candidates.allSatisfy { $0.categoryId == TCGCategory.pokemonJapan })
    }

    /// The picker labels each printing by its qualifier, because "Snivy" three
    /// times over tells him nothing about which one he is holding.
    @Test func theQualifierNamesThePrinting() throws {
        let hits = try Fixture.make().read { db in
            try CatalogSearch.fetchHits(db, ids: [13, 14, 15], filter: SearchFilter())
        }
        let byId = Dictionary(uniqueKeysWithValues: hits.map { ($0.productId, $0) })
        #expect(CardMatcher.qualifier(of: byId[13]!) == nil)
        #expect(CardMatcher.qualifier(of: byId[14]!) == "Poke Ball Pattern")
        #expect(CardMatcher.qualifier(of: byId[15]!) == "Master Ball Pattern")
    }

    // MARK: - Artwork

    /// The fix for his report. The camera sees the Poké Ball pattern stamped
    /// across the card, and the catalog knows what that printing looks like, so
    /// the scanner picks it instead of the plain card and does not ask.
    @Test func artworkPicksThePatternPrinting() throws {
        var observation = ScanObservation(number: "001/086", name: "Snivy")
        observation.artDescriptor = Fixture.snivyPokeBallArt
        let result = try match(observation)
        #expect(result.productId == 14)
        #expect(result.confidence == .certain)
    }

    /// And the other way. The plain card must not be dragged to the printing
    /// just because the printing is worth sixty times as much.
    @Test func artworkPicksThePlainCard() throws {
        var observation = ScanObservation(number: "001/086", name: "Snivy")
        observation.artDescriptor = Fixture.snivyPlainArt
        let result = try match(observation)
        #expect(result.productId == 13)
        #expect(result.confidence == .certain)
    }

    /// TCGplayer has no image for most pattern printings, so for most of them
    /// the artwork cannot decide. It must still ask rather than guess: the
    /// Master Ball printing here has no signature.
    @Test func withoutAReferenceThePatternStillAsks() throws {
        var observation = ScanObservation(number: "001/086", name: "Snivy")
        observation.artDescriptor = Fixture.artDescriptor(seed: 0xDEAD)
        let result = try match(observation)
        #expect(result.confidence == .uncertain)
        #expect(Set(result.candidates.prefix(3).map(\.productId)) == [13, 14, 15])
    }

    /// A Japanese card, where the name on the card can never match the English
    /// name the catalog holds. Artwork is the whole of the evidence, and it is
    /// enough.
    @Test func artworkIdentifiesACardWhoseNameCannotMatch() throws {
        var observation = ScanObservation(number: "020/076", name: "ブラッキー")
        observation.sawJapaneseText = true
        observation.artDescriptor = Fixture.artwork[7]
        let result = try match(observation)
        #expect(result.productId == 7)
        #expect(result.confidence == .certain)
    }

    /// Artwork that agrees with nothing decides nothing. A card in a sleeve
    /// under bad light must not be dragged to whichever candidate happens to be
    /// least unlike it.
    @Test func artworkThatAgreesWithNothingChangesNothing() throws {
        var observation = ScanObservation(number: "020/076")
        observation.artDescriptor = Fixture.artDescriptor(seed: 0xFACE)
        let result = try match(observation)
        #expect(result.confidence == .uncertain)
        #expect(Set(result.candidates.map(\.productId)) == [7, 16])
    }

    /// A catalog built before the signatures existed, or by a different version
    /// of the arithmetic, must be ignored rather than compared against.
    @Test func aCatalogWithNoArtworkIsHarmless() throws {
        let queue = try Fixture.make()
        try queue.write { db in try db.execute(sql: "UPDATE meta SET value = '99' WHERE key = 'artFormatVersion'") }
        var observation = ScanObservation(number: "001/086", name: "Snivy")
        observation.artDescriptor = Fixture.snivyPokeBallArt
        let result = try queue.read { db in
            try CardMatcher.match(db, observation: observation, bias: [], defaultPrinting: nil)
        }
        #expect(result.confidence == .uncertain)
    }

    // MARK: - The rip's set scope

    /// Two cards carry `020/076`, in different sets. With nothing to separate
    /// them the matcher asks, which is right. Knowing which box he is opening
    /// is what separates them.
    @Test func thePreferredSetBreaksATieBetweenTwoCardsSharingANumber() throws {
        let observation = ScanObservation(number: "020/076")
        let unscoped = try match(observation)
        #expect(unscoped.confidence == .uncertain)

        // Tandemaus is groupId 108, Umbreon is 103.
        #expect(try match(observation, preferred: [108]).productId == 16)
        #expect(try match(observation, preferred: [103]).productId == 7)
    }

    /// The scope is a preference and not a filter. A card that is not in the
    /// box he is opening — a stamped print filed elsewhere, a promo, a card
    /// that fell into the wrong pile — must still be reachable and must still
    /// win when its own number and name say so.
    @Test func aCardOutsideThePreferredSetStillWinsOnItsOwnEvidence() throws {
        // Charizard ex 125/197 is groupId 100, and the rip is of groupId 107.
        // One printing, so nothing but the set is left to make it doubtful.
        let observation = ScanObservation(number: "125/197", name: "Charizard ex")
        let result = try match(observation, preferred: [107])
        #expect(result.productId == 1)
        #expect(result.confidence == .certain)
    }

    /// The half of the scope that finds cards rather than ranking them. The
    /// ordinary lookup keys on the printed set total, so a misread denominator
    /// leaves the right card out of the candidates altogether — and no ranking
    /// can rescue a card that was never a candidate.
    @Test func thePreferredSetFindsACardWhoseTotalMisread() throws {
        // Pidgeot ex is 164/197 in groupId 100, and the total reads as 199.
        // No name here on purpose: with one, the name search rescues the card
        // and the widening pass is not what is being tested. This is the card
        // read through glare, where the number is all there is and it is wrong.
        let observation = ScanObservation(number: "164/199")
        #expect(try match(observation).productId == nil)
        #expect(try match(observation, preferred: [100]).productId == 9)
    }

    /// The learned bias and the declared scope both say "this set" and both
    /// apply to the same card, so they stack. Capped together, or a card would
    /// win for being in the expected box over a card whose name the catalog
    /// actually confirms.
    @Test func theTwoSetBiasesDoNotCompoundPastOne() {
        #expect(CardMatcher.setBiasCap <= CardMatcher.nameAgreement)
        #expect(CardMatcher.recentBias + CardMatcher.preferredSetBias > CardMatcher.nameAgreement)
        #expect(min(CardMatcher.recentBias + CardMatcher.preferredSetBias, CardMatcher.setBiasCap)
            < CardMatcher.nameAgreement)
    }

    @Test func reassignFindsTheNumberInAnotherSet() throws {
        let queue = try Fixture.make()
        let found = try queue.read { db in try CardMatcher.product(db, inGroup: 100, numberNum: 164) }
        #expect(found?.productId == 9)
        let missing = try queue.read { db in try CardMatcher.product(db, inGroup: 101, numberNum: 164) }
        #expect(missing == nil)
    }
}

@Suite struct SplitTests {
    @Test func equalSplitSumsExactly() {
        #expect(Split.equally(100_000, into: 3) == [33_334, 33_333, 33_333])
        #expect(Split.equally(497, into: 3) == [166, 166, 165])
        #expect(Split.equally(0, into: 4) == [0, 0, 0, 0])
        #expect(Split.equally(10, into: 0) == [])
        for total in [1, 7, 99, 19_339, 1_000_001] {
            for count in 1...13 {
                #expect(Split.equally(total, into: count).reduce(0, +) == total)
            }
        }
    }
}

@Suite @MainActor struct HeldCopiesTests {
    private func card(_ productId: Int, _ printing: String = "Normal", in session: ScanSession? = nil, context: ModelContext) -> OwnedCard {
        let card = OwnedCard(productId: productId, printing: printing, condition: "Near Mint", confidence: .certain)
        card.scanSession = session
        context.insert(card)
        return card
    }

    /// The inventory's rule: committed and not sold. A copy in this session
    /// is not inventory yet.
    @Test func countsOnlyWhatTheInventoryHolds() throws {
        let container = try CollectionStore.container(inMemory: true)
        let context = container.mainContext
        let committed = ScanSession()
        committed.committedAt = Date()
        context.insert(committed)
        let open = ScanSession()
        context.insert(open)

        _ = card(7, context: context)
        _ = card(7, "Holofoil", in: committed, context: context)
        let sold = card(7, context: context)
        sold.tags = ["Sold"]
        let bulk = card(7, context: context)
        bulk.quantity = 3
        let sealed = card(7, context: context)
        sealed.isSealedSelf = true
        _ = card(7, in: open, context: context)
        _ = card(0, context: context)
        try context.save()

        let model = ScanSessionModel(session: open, context: context, catalog: CatalogController())
        model.loadHeld()
        let scanned = try #require(model.cards.first)

        #expect(model.held == [7: ["Normal": 4, "Holofoil": 1]])
        #expect(model.heldCount(for: scanned) == 5)
        #expect(model.heldCount(for: scanned, printing: "Normal") == 4)
        #expect(model.sessionCount(for: scanned) == 1)
    }

    @Test func theLineNamesThePrintingAndTheSessionCopies() throws {
        let container = try CollectionStore.container(inMemory: true)
        let context = container.mainContext
        let open = ScanSession()
        context.insert(open)
        _ = card(7, "Holofoil", context: context)
        _ = card(7, "Normal", context: context)
        let scanned = card(7, "Holofoil", in: open, context: context)
        scanned.ocrName = "Charizard"
        try context.save()

        let model = ScanSessionModel(session: open, context: context, catalog: CatalogController())
        model.loadHeld()
        #expect(model.copiesLine(for: scanned) == "Charizard: 2 in inventory (1 Holofoil)")

        model.duplicateLast()
        #expect(model.copiesLine(for: scanned) == "Charizard: 2 in inventory (1 Holofoil) · 2 in this scan")

        let fresh = card(9, in: open, context: context)
        fresh.ocrName = "Pikachu"
        #expect(model.copiesLine(for: fresh) == "Pikachu: none in inventory")

        let unknown = card(0, in: open, context: context)
        #expect(model.copiesLine(for: unknown) == nil)
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

    // MARK: - Clean up

    /// The price sweep takes the penny cards and leaves the rest. An unpriced
    /// card is unknown, not cheap, and a slab's raw price is not the slab's.
    @Test @MainActor func thePriceSweepTakesTheCheapCardsOnly() throws {
        let (_, context) = try makeModel()
        let penny = OwnedCard(productId: 1, printing: "Normal", condition: "Near Mint", confidence: .certain)
        let quarter = OwnedCard(productId: 2, printing: "Normal", condition: "Near Mint", confidence: .certain)
        let dear = OwnedCard(productId: 3, printing: "Normal", condition: "Near Mint", confidence: .certain)
        let unpriced = OwnedCard(productId: 4, printing: "Normal", condition: "Near Mint", confidence: .certain)
        let slab = OwnedCard(productId: 5, printing: "Normal", condition: "Near Mint", confidence: .certain)
        slab.certNumber = "12345678"
        slab.graderRaw = "psa"
        slab.gradeLabel = "10"
        for card in [penny, quarter, dear, unpriced, slab] { context.insert(card) }
        let worth: [Int: Int] = [1: 1, 2: 25, 3: 500, 5: 1]

        let cards = [penny, quarter, dear, unpriced, slab]
        let swept = ScanSessionModel.cardsWorth(atMost: 25, in: cards) { worth[$0.productId] }
        #expect(swept.map(\.id) == [penny.id, quarter.id])

        let pennies = ScanSessionModel.cardsWorth(atMost: 1, in: cards) { worth[$0.productId] }
        #expect(pennies.map(\.id) == [penny.id])
    }

    /// A hand-entered card carries its own price, and the sweep reads it.
    @Test @MainActor func thePriceSweepReadsAPriceHeTyped() throws {
        let (model, _) = try makeModel()
        let typed = OwnedCard(productId: 0, printing: "", condition: "Near Mint", confidence: .manual)
        typed.manualName = "Pikachu"
        typed.manualMarketCents = 5
        typed.scanSession = model.session
        #expect(model.cardsWorth(atMost: 10).map(\.id) == [typed.id])
        #expect(model.cardsWorth(atMost: 1).isEmpty)
        // He typed it in, so the unknown sweep leaves it.
        #expect(model.unidentifiedCards.isEmpty)
    }

    @Test @MainActor func theUnknownSweepTakesTheRowsNoCardStandsBehind() throws {
        let (model, _) = try makeModel()
        let unknown = OwnedCard(productId: 0, printing: "", condition: "Near Mint", confidence: .uncertain)
        unknown.ocrName = "Ạạỗl10 G"
        unknown.scanSession = model.session
        let matched = OwnedCard(productId: 7, printing: "Normal", condition: "Near Mint", confidence: .certain)
        matched.scanSession = model.session
        #expect(unknown.isIdentified == false)
        #expect(model.cards.count == 2)
        #expect(model.unidentifiedCards.count == 1)

        model.delete(model.unidentifiedCards)
        #expect(model.cards.map(\.id) == [matched.id])
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

    /// **The other half of "it will not add a card to the collection".** One
    /// card the matcher could not place used to disable the Commit button, so
    /// a whole rip stayed out of the collection until every last row was
    /// fixed. An unidentified card commits as unidentified: `productId` 0 is a
    /// shape the store already models and the inventory already renders, and
    /// he can identify it later from there.
    @Test @MainActor func aSessionHoldingAnUnidentifiedCardStillCommits() throws {
        let (model, context) = try makeModel()
        let known = OwnedCard(productId: 1, printing: "Holofoil", condition: "Near Mint", confidence: .certain)
        known.scanSession = model.session
        context.insert(known)
        let unknown = OwnedCard(productId: 0, printing: "", condition: "Near Mint", confidence: .uncertain)
        unknown.scanSession = model.session
        context.insert(unknown)

        model.commit()

        #expect(model.session.isCommitted)
        #expect(model.cards.count == 2)
        // Both reach the collection, and the unidentified one is still
        // findable as unidentified rather than quietly becoming something.
        #expect(model.cards.allSatisfy { $0.isCommitted })
        #expect(model.cards.contains { !$0.isIdentified })
    }

    /// A card logged on its picture alone carries no words, and `isEmpty` asks
    /// only about words. The guard at the top of `handle` used to drop it here
    /// — after the loop had decided to log it, and without a word anywhere.
    @Test @MainActor func anObservationWithOnlyArtworkIsNotDiscarded() throws {
        let (model, _) = try makeModel()
        var observation = ScanObservation()
        observation.sawCard = true
        observation.artDescriptor = Fixture.artDescriptor(seed: 0xFACE)
        #expect(!observation.isEmpty == false)

        // No catalog is open in this suite, so the matcher cannot run. What is
        // being proved is that it got that far: the fault is reported rather
        // than the observation being dropped in silence.
        model.handle(observation)
        #expect(model.fault == .catalogClosed)
    }

    /// A commit makes the cards inventory. It makes no purchase and no
    /// purchase line, and no card points at one.
    @Test @MainActor func commitAddsTheCardsAndNoPurchase() throws {
        let (model, context) = try makeModel()
        for id in [1, 2, 3] {
            let card = OwnedCard(productId: id, printing: "Holofoil", condition: "Near Mint", confidence: .certain)
            card.scanSession = model.session
            context.insert(card)
        }
        model.duplicateLast()
        #expect(model.cards.count == 4)

        model.commit()

        #expect(model.session.isCommitted)
        #expect(model.session.purchase == nil)
        #expect(try context.fetchCount(FetchDescriptor<Purchase>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PurchaseItem>()) == 0)
        #expect(model.cards.allSatisfy { $0.isCommitted && $0.sourceItem == nil })
    }

    /// Ripping a sealed card: the commit deletes the pack, the pulls stay as
    /// the scan made them, and the purchase that bought the pack does not change.
    @Test @MainActor func commitOfARipDeletesThePacksAndKeepsThePulls() throws {
        let context = container.mainContext
        let defaults = try #require(UserDefaults(suiteName: "ScanTests.\(UUID().uuidString)"))
        let purchase = Purchase(vendor: "Walmart", itemCostCents: 5_000)
        context.insert(purchase)
        let box = OwnedCard(productId: 1, printing: "", condition: "Near Mint", confidence: .manual)
        box.isSealedSelf = true
        context.insert(box)
        let other = OwnedCard(productId: 2, printing: "Normal", condition: "Near Mint", confidence: .certain)
        context.insert(other)

        let session = try #require(Rip.start([box], context: context, defaults: defaults))
        let model = ScanSessionModel(session: session, context: context, catalog: CatalogController(), defaults: defaults)
        for id in [10, 11] {
            let pulled = OwnedCard(productId: id, printing: "Normal", condition: "Near Mint", confidence: .certain)
            pulled.scanSession = session
            context.insert(pulled)
        }

        model.commit()

        let cards = try context.fetch(FetchDescriptor<OwnedCard>())
        #expect(!cards.contains { $0.id == box.id })
        #expect(cards.contains { $0.id == other.id })
        #expect(model.cards.map(\.productId).sorted() == [10, 11])
        #expect(model.cards.allSatisfy { $0.isCommitted && $0.sourceItem == nil })
        #expect(try context.fetchCount(FetchDescriptor<PurchaseItem>()) == 0)
        #expect(purchase.landedCostCents == 5_000)
        #expect(!Rip.isRip(session, defaults: defaults))
    }

    @Test @MainActor func sessionBiasKeepsTheNewestSetsFirst() {
        let session = ScanSession()
        for id in [100, 101, 100, 102] { session.observe(groupId: id) }
        #expect(session.observedGroupIds == [102, 100, 101])
    }

    private func promoLine(_ text: String, top: CGFloat, height: CGFloat) -> RecognizedText {
        RecognizedText(id: UUID(), transcript: text, top: top, height: height)
    }

    /// A promo or an Energy prints "MEP EN 109", and Vision splits it into a
    /// code line and a digits line. These are the lines Vision read off
    /// TCGplayer's own images, misreads included.
    @Test func aPromoNumberSplitOverTwoLinesIsJoined() {
        func number(_ lines: [(String, CGFloat)]) -> String? {
            FrameInterpreter.interpret(lines.map { promoLine($0.0, top: $0.1, height: 0.02) }).observation.number
        }
        #expect(number([("Basic Energy", 0.05), ("MEE EN", 0.93), ("001", 0.935)]) == "MEE001")
        #expect(number([("MEE EX", 0.93), ("002", 0.93)]) == "MEE002")
        #expect(number([("Pikachu eX", 0.05), ("200", 0.6), ("J MEP EN", 0.92), ("109", 0.925)]) == "MEP109")
        #expect(number([("MEE EN", 0.93), ("016 Illus. YOSHIROTTEN", 0.935)]) == "MEE016")
        // The damage further up the card is not the number.
        #expect(number([("200", 0.6), ("J MEP EN", 0.92)]) == nil)
    }

    @Test func aPromoNumberOnOneLineDropsTheLanguageCode() {
        #expect(FrameInterpreter.number(in: ["J MEP# 108"])?.value == "MEP108")
        #expect(FrameInterpreter.number(in: ["MEP EN 109"])?.value == "MEP109")
        #expect(CollectorNumber.parse("MEP109") == CollectorNumber(numberNum: 109, setCode: "MEP"))
    }

    /// The code and the digits are not a name.
    @Test func thePromoLinesAreNotNameCandidates() {
        let observation = FrameInterpreter.interpret([
            promoLine("Pikachu ex", top: 0.05, height: 0.05),
            promoLine("J MEP EN", top: 0.92, height: 0.02),
            promoLine("109", top: 0.925, height: 0.02),
        ]).observation
        #expect(!observation.nameCandidates.contains("J MEP EN"))
        #expect(observation.name == "Pikachu ex")
    }
}
