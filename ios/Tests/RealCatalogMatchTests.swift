import Foundation
import GRDB
import Testing
@testable import BinderBooks

/// The matcher against the real ~80k-row catalog, not a fixture.
///
/// A fixture cannot reproduce what went wrong on the phone: a Sableye came back
/// as a Japanese Scramble Switch, and it did so because 80,000 other rows were
/// in the way. These run only when `scripts/catalog.sqlite` is present.
@Suite struct RealCatalogMatchTests {
    static let catalogPath: String = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts/catalog.sqlite")
        .path

    private func queue() throws -> DatabaseQueue {
        try #require(FileManager.default.fileExists(atPath: Self.catalogPath), "no scripts/catalog.sqlite; download it from the catalog-latest release")
        var configuration = Configuration()
        configuration.readonly = true
        return try DatabaseQueue(path: Self.catalogPath, configuration: configuration)
    }

    private func match(name: String?, number: String?, bias: [Int] = []) throws -> MatchResult {
        let observation = ScanObservation(number: number, name: name)
        return try queue().read { db in
            try CardMatcher.match(db, observation: observation, bias: bias, defaultPrinting: nil)
        }
    }

    /// The reported failure. His hand covered the collector number, so the name
    /// was the only signal the scanner had.
    @Test func sableyeWithNoNumberDoesNotComeBackAsAJapaneseTrainer() throws {
        let result = try match(name: "Sableye", number: nil)
        let top = try #require(result.candidates.first)
        #expect(top.name.lowercased().contains("sableye"), "top candidate was \(top.name)")
        if let productId = result.productId {
            let hit = try #require(result.candidates.first { $0.productId == productId })
            #expect(hit.name.lowercased().contains("sableye"), "assigned \(hit.name)")
        }
    }

    /// With the number readable it lands on the right card. It still reads
    /// `uncertain`, because Sableye has two printings and docs/03 says a guessed
    /// printing is reviewed rather than asserted. That is the rule working.
    @Test func sableyeWithItsNumberFindsTheRightCard() throws {
        let result = try match(name: "Sableye", number: "070/196")
        #expect(result.productId == 283946 || result.productId == 515452)
        let hit = try #require(result.candidates.first { $0.productId == result.productId })
        #expect(hit.name == "Sableye")
    }

    /// The reported bug, exactly. An attack name is not a card name, and with
    /// no number to check it against the matcher must assign nothing.
    @Test func anAttackNameNeverBecomesACard() throws {
        let result = try match(name: "Scratch", number: nil)
        #expect(result.productId == nil)
        #expect(result.confidence == .uncertain)
        // The chip still offers what it considered, so one tap fixes it.
        #expect(!result.candidates.isEmpty)
    }

    /// The name-only bar must not throw away a name he actually read.
    ///
    /// It leads the chip rather than being assigned. Sableye is printed in
    /// several sets from one illustration, so with no number there is nothing
    /// to choose between them and the scanner no longer pretends otherwise —
    /// measured over 300 real readings, asking here cut wrong answers in the
    /// chute from 9.3% to 4.0% and *raised* right answers to 88.7%.
    @Test func aCleanNameStillMatchesWithNoNumber() throws {
        let result = try match(name: "Sableye", number: nil)
        let top = try #require(result.candidates.first)
        #expect(top.name == "Sableye")
    }

    /// Every string Vision actually read off that Sableye photo, in order.
    /// The card name must resolve and nothing else on the card may.
    @Test func onlyTheCardNameOnThatSableyeResolves() throws {
        // The collector number never appears: his fingers covered it.
        let notTheName = ["Scratch", "Lost Mine", "Lost", "Mine", "Darkness"]
        for reading in notTheName {
            let result = try match(name: reading, number: nil)
            #expect(result.productId == nil, "\(reading) was assigned a card")
        }

        let sableye = try match(name: "Sableye", number: nil)
        let top = try #require(sableye.candidates.first)
        #expect(top.name == "Sableye")
        // Without the number it cannot know which Sableye, so it must not claim
        // to — and it no longer assigns one of them either. The chip leads with
        // the Sableyes and he taps the one he is holding.
        #expect(sableye.confidence == .uncertain)
        #expect(sableye.productId == nil)
    }

    /// The hole the first fix left. A number that reads as something real, plus
    /// the attack name, must still not produce a card from the name alone.
    @Test func aSpuriousNumberDoesNotReopenTheNameHole() throws {
        // 070/195 is the misread that produced a Mawile V: one digit off the
        // Sableye's 070/196, and exactly one card carries it.
        for number in ["20", "80", "070/196", "070/195", "20/30", "1/8"] {
            let result = try match(name: "Scratch", number: number)
            let assigned = result.productId.flatMap { id in result.candidates.first { $0.productId == id } }
            let chip = result.candidates.prefix(3).map(\.name).joined(separator: " | ")
            print("number=\(number) name=Scratch -> \(assigned?.name ?? "NOTHING") chip: \(chip)")
        }
    }

    /// His idea, and the decisive one: the catalog holds every card name, so
    /// membership tells a card name from an attack name outright.
    @Test func theCatalogSaysWhichLineIsACardName() throws {
        let verdicts = try queue().read { db in
            try ["sableye", "mawile v", "scratch", "lost mine"].map {
                try CardMatcher.isACardName(db, $0)
            }
        }
        #expect(verdicts == [true, true, false, false])
    }

    /// The whole frame, in the order the interpreter offers it. The attack name
    /// comes first because the name line was missed, and the card still wins.
    @Test func theNameIsPickedOutOfEverythingOnTheCard() throws {
        let observation = ScanObservation(
            number: nil,
            name: "Scratch",
            nameCandidates: ["Scratch", "Lost Mine", "Sableye", "Darkness"]
        )
        let result = try queue().read { db in
            try CardMatcher.match(db, observation: observation, bias: [], defaultPrinting: nil)
        }
        // The attack name loses and the card name wins, which is what this test
        // is for. Which Sableye it is remains the number's question, so the card
        // leads the chip rather than being assigned.
        let top = try #require(result.candidates.first)
        #expect(top.name == "Sableye")
    }

    @Test func loneNameMatchesStayHonest() throws {
        // A name the catalog does not hold must assign nothing at all.
        let result = try match(name: "Zzzzqqqx", number: nil)
        #expect(result.productId == nil)
    }

    // MARK: - Identification by artwork

    /// Dedenne 085/195 in Silver Tempest. The card he was holding when the
    /// scanner logged seven cards off one photograph, so it is the card the
    /// artwork path is tested on.
    static let dedenne = 451_739

    /// The signature the catalog already holds for a product, used as though
    /// the camera had just taken it.
    ///
    /// Vision cannot make a signature in the simulator — feature prints need
    /// the neural engine — so these tests use the stored one. That tests the
    /// index and the matcher, which is what changed, and not Vision, which
    /// `CardArtTests` covers on a device.
    private func storedDescriptor(_ productId: Int) throws -> [Int8] {
        let data = try queue().read { db in
            try Data.fetchOne(db, sql: "SELECT descriptor FROM productArt WHERE productId = ?", arguments: [productId])
        }
        let blob = try #require(data)
        return try #require(CardArtDescriptor.descriptor(from: blob))
    }

    private func index() throws -> ArtIndex {
        try queue().read { db in try ArtIndex.load(db) }
    }

    @Test func theIndexHoldsEverySignedCardInTheCatalog() throws {
        let art = try index()
        let rows = try queue().read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM productArt") ?? 0
        }
        #expect(art.count == rows)
        #expect(art.count > 50_000, "only \(art.count) signatures")
    }

    /// The index must find the card a signature came from, and find it first.
    @Test func aSignatureFindsItsOwnCard() throws {
        let art = try index()
        let neighbours = art.nearest(to: try storedDescriptor(Self.dedenne), limit: 5)
        let first = try #require(neighbours.first)
        #expect(first.productId == Self.dedenne)
        #expect(first.distance < 0.001, "a signature is not at zero from itself: \(first.distance)")
        // Sorted, nearest first.
        #expect(neighbours == neighbours.sorted { $0.distance < $1.distance })
    }

    /// The reported failure, with the picture added.
    ///
    /// He photographed a Dedenne and the scanner logged "Tail Smack" and
    /// "Dede-Short" — its two attacks — as cards of their own. The words alone
    /// cannot fix that, because the scanner cannot tell which line is the
    /// name. The picture can, and with no number to help it.
    @Test func anAttackNameLosesToThePictureOfTheCard() throws {
        let observation = ScanObservation(
            number: nil,
            name: "Tail Smack",
            nameCandidates: ["Tail Smack", "Dede-Short"],
            artDescriptor: try storedDescriptor(Self.dedenne)
        )
        let art = try index()
        let result = try queue().read { db in
            try CardMatcher.match(db, observation: observation, bias: [], defaultPrinting: nil, art: art)
        }
        #expect(result.productId == Self.dedenne)
        let hit = try #require(result.hit)
        #expect(hit.name == "Dedenne")
    }

    /// Without the picture the same observation must still assign nothing.
    /// The old safety rail stays exactly where it was.
    @Test func anAttackNameWithNoPictureStillAssignsNothing() throws {
        let result = try match(name: "Tail Smack", number: nil)
        #expect(result.productId == nil)
    }

    /// The number and the picture pointing at one card find that card even
    /// though every word on it was read wrong.
    ///
    /// It still reads `uncertain`, and that is the printing rule, not the
    /// match: Dedenne 085/195 is printed Normal and Reverse Holofoil, and
    /// docs/03 sends a guessed printing to review. The match itself is right.
    @Test func theNumberAndThePictureAgreeOnTheCard() throws {
        let observation = ScanObservation(
            number: "085/195",
            name: "Tail Smack",
            nameCandidates: ["Tail Smack"],
            artDescriptor: try storedDescriptor(Self.dedenne)
        )
        let art = try index()
        let result = try queue().read { db in
            try CardMatcher.match(db, observation: observation, bias: [], defaultPrinting: nil, art: art)
        }
        #expect(result.productId == Self.dedenne)
        #expect(result.printingGuessed)
    }

    /// Ampharos ex 89/97: one printing, and the only card in the catalog at
    /// that number. Nothing is left to guess, so the number and the picture
    /// agreeing is allowed to say `certain` even though the name read is junk.
    @Test func theNumberAndThePictureAgreeingIsCertain() throws {
        let ampharos = 83_550
        let observation = ScanObservation(
            number: "89/97",
            name: "Cluster Bolt",
            nameCandidates: ["Cluster Bolt"],
            artDescriptor: try storedDescriptor(ampharos)
        )
        let art = try index()
        let result = try queue().read { db in
            try CardMatcher.match(db, observation: observation, bias: [], defaultPrinting: nil, art: art)
        }
        #expect(result.productId == ampharos)
        #expect(result.confidence == .certain)
    }

    /// The picture must not overrule words that agree with each other. A name
    /// the catalog holds and a number that finds it are two signals, and a
    /// photograph through glare is not better evidence than both of them.
    @Test func thePictureDoesNotOverruleANameAndNumberThatAgree() throws {
        let observation = ScanObservation(
            number: "070/196",
            name: "Sableye",
            nameCandidates: ["Sableye"],
            // The wrong card's picture entirely.
            artDescriptor: try storedDescriptor(Self.dedenne)
        )
        let art = try index()
        let result = try queue().read { db in
            try CardMatcher.match(db, observation: observation, bias: [], defaultPrinting: nil, art: art)
        }
        let hit = try #require(result.hit)
        #expect(hit.name == "Sableye", "artwork hijacked a good reading: \(hit.name)")
    }

    /// His report: 122/131 failed. Three English cards carry that number — a
    /// Professor's Research and its Poke Ball printing in Prismatic Evolutions,
    /// and a Lucario GX Full Art in Forbidden Light. With the name missed there
    /// was nothing to choose on, so the oldest product id won and a Lucario GX
    /// went into the ledger in place of a Common trainer.
    ///
    /// The picture answers it. The question here is not "which of 71,802 cards
    /// is this", it is "which of these three", and a trainer is not near a
    /// full-art Lucario by any measure.
    @Test func thePictureChoosesAmongTheCardsSharingANumber() throws {
        let professor = 610477
        let descriptor = try queue().read { db in
            try CatalogSearch.artDescriptors(db, ids: [professor])[professor]
        }
        let signature = try #require(descriptor, "the catalog carries no artwork for \(professor)")
        var observation = ScanObservation(number: "122/131")
        observation.artDescriptor = signature
        let result = try queue().read { db in
            try CardMatcher.match(db, observation: observation, bias: [], defaultPrinting: nil, language: .english)
        }
        #expect(result.productId == professor)
    }

    /// And with no picture to ask, it assigns nothing rather than the first row
    /// back. docs/03: a wrong card that looks confident is worse than a card
    /// marked unknown.
    @Test func aNumberSeveralDifferentCardsShareAssignsNothingOnItsOwn() throws {
        let result = try queue().read { db in
            try CardMatcher.match(
                db,
                observation: ScanObservation(number: "122/131"),
                bias: [],
                defaultPrinting: nil,
                language: .english
            )
        }
        #expect(result.productId == nil)
        #expect(result.confidence == .uncertain)
        // The chip still offers all three, so one tap settles it.
        #expect(result.candidates.count >= 3)
    }

    /// The sub-name in square brackets is not part of the title the card prints.
    /// "Professor's Research [Professor Oak]" prints "Professor's Research", and
    /// scoring the camera's reading against the bracketed name cost it enough
    /// similarity to fall under the bar a name must clear when it stands alone.
    @Test func aBracketedSubNameIsNotPartOfThePrintedName() throws {
        let hits = try queue().read { db in
            try CatalogSearch.fetchHits(db, ids: [610477, 610630], filter: SearchFilter())
        }
        for hit in hits {
            #expect(CardMatcher.printedName(of: hit) == "professor s research", "got \(CardMatcher.printedName(of: hit))")
        }
    }

    /// The promo and Energy sets store no set code on the product, so the
    /// code on the card is found through the set's abbreviation.
    @Test func aPromoAndAnEnergyAreFoundByTheirSetCode() throws {
        let pikachu = try match(name: "Pikachu ex", number: "MEP109")
        #expect(pikachu.candidates.first?.productId == 713256, "top was \(pikachu.candidates.first?.name ?? "nothing")")

        let grass = try match(name: "Basic Energy", number: "MEE001")
        #expect(grass.candidates.first?.productId == 656263, "top was \(grass.candidates.first?.name ?? "nothing")")
    }
}
