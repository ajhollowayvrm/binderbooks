import Foundation
import Testing
@testable import BinderBooks

@Suite struct PPTClientTests {
    /// The shape a real `/cards?tcgPlayerId=` answer has, captured from PPT
    /// on 2026-09-10: one card under `data`, an id written as a string, and
    /// the grade buckets keyed `psa10` / `cgc9_5`. The first build guessed a
    /// list under `data` and read nothing at all, so this fixture is the one
    /// that matters.
    let body = """
    {"data": {
        "id": "696f656a67063f37df81fa25",
        "tcgPlayerId": "232613",
        "name": "Crobat VMAX - SWSH099",
        "prices": {"market": 2.12},
        "ebay": {"salesByGrade": {
            "psa10": {"count": 2, "averagePrice": 138.97, "medianPrice": 138.97, "smartMarketPrice": {"price": 123.97, "confidence": "low"}},
            "psa9": {"count": 1, "averagePrice": 17.18, "marketPrice7Day": null, "smartMarketPrice": {"price": 17.18}},
            "psa7": {"count": 1, "averagePrice": 2.3, "smartMarketPrice": {"price": 2.3}},
            "cgc10": {"count": 6, "averagePrice": 14.228333333333333, "smartMarketPrice": {"price": 16.25}},
            "cgc9_5": {"count": 2, "averagePrice": 13.5, "smartMarketPrice": {"price": 12.38}},
            "cgc8": {"count": 1, "averagePrice": 5, "smartMarketPrice": {"price": 4.25}},
            "ace10": {"count": 1, "smartMarketPrice": {"price": 30}},
            "tag10": {"count": 1, "marketPrice7Day": 99.99},
            "ungraded": {"count": 5, "averagePrice": 11.2, "smartMarketPrice": {"price": 16.48}}
        }}
    }, "metadata": {"total": 1, "apiCallsConsumed": {"total": 2, "costPerCard": 2}}}
    """

    @Test func theRealAnswerShapeIsRead() throws {
        let comps = try #require(try PPTClient.parse(Data(body.utf8), tcgPlayerId: 232613))
        #expect(comps["PSA 10"] == 12_397)
        #expect(comps["PSA 9"] == 1_718)
        #expect(comps["PSA 7"] == 230)
        #expect(comps["CGC 10"] == 1_625)
        #expect(comps["CGC 9.5"] == 1_238)
        #expect(comps["CGC 8"] == 425)
        // PPT tracks graders the app does not name. An allowlist would drop them.
        #expect(comps["ACE 10"] == 3_000)
        #expect(comps["TAG 10"] == 9_999)
        // A raw sale is not a grade.
        #expect(comps.keys.contains { $0.lowercased().contains("ungraded") } == false)
    }

    @Test func aWrongProductIsNotAccepted() throws {
        #expect(try PPTClient.parse(Data(body.utf8), tcgPlayerId: 1) == nil)
    }

    @Test func theOtherShapesStillRead() throws {
        let card = """
        {"tcgPlayerId": 558123, "ebay": {"salesByGrade": {"psa10": {"smartMarketPrice": {"price": 120.10}}}}}
        """
        #expect(try PPTClient.parse(Data("{\"cards\": [\(card)]}".utf8), tcgPlayerId: 558123)?["PSA 10"] == 12_010)
        #expect(try PPTClient.parse(Data("{\"data\": [\(card)]}".utf8), tcgPlayerId: 558123)?["PSA 10"] == 12_010)
        #expect(try PPTClient.parse(Data("[\(card)]".utf8), tcgPlayerId: 558123)?["PSA 10"] == 12_010)
        #expect(try PPTClient.parse(Data(card.utf8), tcgPlayerId: 558123)?["PSA 10"] == 12_010)
    }

    @Test func gradeKeys() {
        #expect(PPTClient.gradeLabel(forBucket: "psa10") == "PSA 10")
        #expect(PPTClient.gradeLabel(forBucket: "cgc9_5") == "CGC 9.5")
        #expect(PPTClient.gradeLabel(forBucket: "bgs10") == "BGS 10")
        #expect(PPTClient.gradeLabel(forBucket: "ace9") == "ACE 9")
        #expect(PPTClient.gradeLabel(forBucket: "ungraded") == nil)
        #expect(PPTClient.gradeLabel(forBucket: "psaGem") == nil)
    }

    @Test func nonsenseIsUnreadable() {
        #expect(throws: PPTClient.Failure.unreadable) {
            try PPTClient.parse(Data("not json".utf8), tcgPlayerId: 1)
        }
    }

    @Test @MainActor func aGradedCardIsASlabWithoutACertNumber() {
        // The imported ledger recorded the grade and never a cert, so a cert
        // test hid every one of his 35 graded cards behind a plain thumbnail.
        let card = OwnedCard(productId: 1, printing: "Holofoil", condition: "Near Mint", confidence: .manual)
        #expect(card.isSlabbed == false)
        card.graderRaw = "cgc"
        card.gradeLabel = "Pristine 10"
        #expect(card.isSlabbed)

        let scanned = OwnedCard(productId: 2, printing: "", condition: "Near Mint", confidence: .uncertain)
        scanned.certNumber = "12345678"
        #expect(scanned.isSlabbed)
    }

    @Test @MainActor func hisFigureWinsOverTheFetchedOne() {
        let card = OwnedCard(productId: 1, printing: "Holofoil", condition: "Near Mint", confidence: .manual)
        card.fetchedCompCents = ["PSA 10": 12_000, "PSA 9": 4_000]
        card.gradedCompCents = ["PSA 10": 15_000]
        #expect(card.effectiveCompCents == ["PSA 10": 15_000, "PSA 9": 4_000])
        #expect(GradedComps.range(for: "psa", in: card.effectiveCompCents) == 4_000...15_000)
    }
}
