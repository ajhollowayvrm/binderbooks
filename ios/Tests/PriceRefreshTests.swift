import Foundation
import GRDB
import Testing
@testable import BinderBooks

/// New prices from TCGCSV, and the rule that allows a refresh only when TCGCSV
/// is newer than the prices on his cards.
@Suite struct PriceRefreshTests {
    @Test func theSourceDateIsTheUTCDay() {
        #expect(PriceRefresh.parseLastUpdated("2026-09-17T20:05:48+0000\n") == "2026-09-17")
        // 23:30 in Denver is the next day in UTC.
        #expect(PriceRefresh.parseLastUpdated("2026-09-17T23:30:00-0600") == "2026-09-18")
        #expect(PriceRefresh.parseLastUpdated("yesterday") == nil)
    }

    @Test func pricesBecomeCentsTheWayTheMacBuildRoundsThem() {
        #expect(PriceRefresh.cents(NSNumber(value: 0.35)) == 35)
        #expect(PriceRefresh.cents(NSNumber(value: 68.6)) == 6_860)
        // Half up, like ROUND_HALF_UP in build_catalog.py.
        #expect(PriceRefresh.cents(NSNumber(value: 1.005)) == 101)
        #expect(PriceRefresh.cents(NSNumber(value: 12)) == 1_200)
        #expect(PriceRefresh.cents(NSNull()) == nil)
        #expect(PriceRefresh.cents(nil) == nil)
    }

    @Test func tcgcsvPricesParse() throws {
        let body = """
        {"success": true, "errors": [], "results": [
          {"productId": 1, "lowPrice": 40.0, "midPrice": 50.5, "highPrice": 99.99, "marketPrice": 46.12, "directLowPrice": null, "subTypeName": "Holofoil"},
          {"productId": 3, "lowPrice": null, "midPrice": null, "highPrice": null, "marketPrice": 0.11, "directLowPrice": null, "subTypeName": "Normal"}
        ]}
        """
        let rows = try #require(PriceRefresh.parsePrices(Data(body.utf8)))
        #expect(rows == [
            PriceRefresh.PriceRow(productId: 1, subTypeName: "Holofoil", marketCents: 4_612, lowCents: 4_000, midCents: 5_050, highCents: 9_999, directLowCents: nil),
            PriceRefresh.PriceRow(productId: 3, subTypeName: "Normal", marketCents: 11, lowCents: nil, midCents: nil, highCents: nil, directLowCents: nil),
        ])
        #expect(PriceRefresh.parsePrices(Data("<html>".utf8)) == nil)
    }

    @Test func aRefreshReplacesTheSetsPricesAndDatesThem() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("prices-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try Fixture.make(path: url.path).close()

        let before = try DatabaseQueue(path: url.path)
        // Charizard ex (1) and Charmander (3) are in set 100. Charizard (2) is in 101.
        let groups = try before.read { try PriceRefresh.groups($0, productIds: [1, 3]) }
        #expect(groups == [PriceRefresh.Group(groupId: 100, categoryId: 3)])
        #expect(try before.read { try PriceRefresh.oldestPriceDate($0, productIds: [1, 3]) } == "2026-09-10")
        try before.close()

        let rows = [
            PriceRefresh.PriceRow(productId: 1, subTypeName: "Holofoil", marketCents: 4_900, lowCents: 4_100, midCents: nil, highCents: nil, directLowCents: nil),
            // Charmander's Reverse Holofoil is gone from TCGCSV, so its old row must go.
            PriceRefresh.PriceRow(productId: 3, subTypeName: "Normal", marketCents: 12, lowCents: 9, midCents: nil, highCents: nil, directLowCents: nil),
            // Not in the catalog yet. It waits for the next publish.
            PriceRefresh.PriceRow(productId: 999_999, subTypeName: "Normal", marketCents: 5, lowCents: nil, midCents: nil, highCents: nil, directLowCents: nil),
        ]
        try PriceRefresh.apply(rows, groups: groups, asOf: "2026-09-18", to: url)

        let after = try DatabaseQueue(path: url.path)
        defer { try? after.close() }
        try after.read { db in
            let set100 = try GRDB.Row.fetchAll(db, sql: "SELECT productId, subTypeName, marketPriceCents, asOf FROM price WHERE productId IN (1, 3) ORDER BY productId, subTypeName")
            #expect(set100.map { [$0["productId"] as Int, $0["marketPriceCents"] as Int] } == [[1, 4_900], [3, 12]])
            #expect(set100.allSatisfy { ($0["asOf"] as String) == "2026-09-18" })
            // Another set keeps its prices and its date.
            #expect(try Int.fetchOne(db, sql: "SELECT marketPriceCents FROM price WHERE productId = 2 AND subTypeName = 'Holofoil'") == 30_000)
            #expect(try PriceRefresh.oldestPriceDate(db, productIds: [2]) == "2026-09-10")
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM price WHERE productId = 999999") == 0)
            #expect(try PriceRefresh.oldestPriceDate(db, productIds: [1, 3]) == "2026-09-18")
        }
    }

    @Test func refreshIsOnOnlyWhenTCGCSVIsNewer() {
        typealias Button = PriceRefreshButton
        #expect(Button.presentation(.available(source: "2026-09-18", oldest: "2026-09-17")).action == .refresh)
        #expect(Button.presentation(.current("2026-09-17")).action == nil)
        #expect(Button.presentation(.checking).action == nil)
        #expect(Button.presentation(.refreshing(done: 3, total: 69)).action == nil)
        #expect(Button.presentation(.failed("offline")).action == .check)
        #expect(Button.presentation(.available(source: "2026-09-18", oldest: "2026-09-17")).detail == "TCGCSV has Sep 18 prices. Yours are from Sep 17.")
        #expect(Button.day("2026-09-17") == "Sep 17")
    }
}
