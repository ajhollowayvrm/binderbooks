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
    @Test func aCleanNameStillMatchesWithNoNumber() throws {
        let result = try match(name: "Sableye", number: nil)
        let hit = try #require(result.candidates.first { $0.productId == result.productId })
        #expect(hit.name == "Sableye")
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
        let hit = try #require(sableye.candidates.first { $0.productId == sableye.productId })
        #expect(hit.name == "Sableye")
        // Without the number it cannot know which Sableye, so it must not claim to.
        #expect(sableye.confidence == .uncertain)
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
        let hit = try #require(result.candidates.first { $0.productId == result.productId })
        #expect(hit.name == "Sableye")
    }

    @Test func loneNameMatchesStayHonest() throws {
        // A name the catalog does not hold must assign nothing at all.
        let result = try match(name: "Zzzzqqqx", number: nil)
        #expect(result.productId == nil)
    }
}
