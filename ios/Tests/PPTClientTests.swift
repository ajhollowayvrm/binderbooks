import Foundation
import Testing
@testable import BinderBooks

@Suite struct PPTClientTests {
    let body = """
    {"tcgPlayerId": 558123, "name": "Charizard ex", "ebay": {"salesByGrade": {
        "psa10": {"smartMarketPrice": {"price": 120.10}, "averagePrice": 90, "count": 14},
        "psa9": {"marketPrice7Day": 41.99, "count": 6},
        "psa8": {"averagePrice": 0, "count": 0},
        "cgc9_5": {"medianPrice": 33.5, "count": 2},
        "cgc10pristine": {"smartMarketPrice": {"price": 250}, "count": 1},
        "ungraded": {"smartMarketPrice": {"price": 20}, "count": 40},
        "tag10": {"smartMarketPrice": {"price": 99.99}}
    }}}
    """

    @Test func bucketsBecomeTheAppsKeysInCents() throws {
        let comps = try #require(try PPTClient.parse(Data(body.utf8), tcgPlayerId: 558123))
        #expect(comps["PSA 10"] == 12_010)
        #expect(comps["PSA 9"] == 4_199)
        #expect(comps["PSA 8"] == nil)
        #expect(comps["CGC 9.5"] == 3_350)
        #expect(comps["CGC Pristine 10"] == 25_000)
        #expect(comps["TAG 10"] == 9_999)
        #expect(comps.keys.contains { $0.lowercased().contains("ungraded") } == false)
    }

    @Test func aWrongProductIsNotAccepted() throws {
        #expect(try PPTClient.parse(Data(body.utf8), tcgPlayerId: 1) == nil)
    }

    @Test func listShapesAreRead() throws {
        let wrapped = Data("{\"cards\": [\(body)]}".utf8)
        #expect(try PPTClient.parse(wrapped, tcgPlayerId: 558123)?["PSA 10"] == 12_010)
        let data = Data("{\"data\": [\(body)]}".utf8)
        #expect(try PPTClient.parse(data, tcgPlayerId: 558123)?["PSA 9"] == 4_199)
        let bare = Data("[\(body)]".utf8)
        #expect(try PPTClient.parse(bare, tcgPlayerId: 558123)?["CGC 9.5"] == 3_350)
        let stringId = Data(body.replacingOccurrences(of: "558123", with: "\"558123\"").utf8)
        #expect(try PPTClient.parse(stringId, tcgPlayerId: 558123)?["PSA 10"] == 12_010)
    }

    @Test func gradeKeys() {
        #expect(PPTClient.gradeLabel(forBucket: "psa10") == "PSA 10")
        #expect(PPTClient.gradeLabel(forBucket: "cgc9_5") == "CGC 9.5")
        #expect(PPTClient.gradeLabel(forBucket: "bgs10") == "BGS 10")
        #expect(PPTClient.gradeLabel(forBucket: "cgcPristine10") == "CGC Pristine 10")
        #expect(PPTClient.gradeLabel(forBucket: "ungraded") == nil)
        #expect(PPTClient.gradeLabel(forBucket: "psaGem") == nil)
    }

    @Test func nonsenseIsUnreadable() {
        #expect(throws: PPTClient.Failure.unreadable) {
            try PPTClient.parse(Data("not json".utf8), tcgPlayerId: 1)
        }
    }

    @Test @MainActor func hisFigureWinsOverTheFetchedOne() {
        let card = OwnedCard(productId: 1, printing: "Holofoil", condition: "Near Mint", confidence: .manual)
        card.fetchedCompCents = ["PSA 10": 12_000, "PSA 9": 4_000]
        card.gradedCompCents = ["PSA 10": 15_000]
        #expect(card.effectiveCompCents == ["PSA 10": 15_000, "PSA 9": 4_000])
        #expect(GradedComps.range(for: "psa", in: card.effectiveCompCents) == 4_000...15_000)
    }
}
