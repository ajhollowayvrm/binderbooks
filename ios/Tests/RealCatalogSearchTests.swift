import Foundation
import GRDB
import Testing
@testable import BinderBooks

/// The search field against the real ~80k-row catalog, with queries that can
/// mean more than one thing.
///
/// Every case here failed on the real catalog before the fix that names it. A
/// fixture of sixteen rows could not show any of them: each one needs thousands
/// of other rows in the way. These run only when `scripts/catalog.sqlite` is
/// present. Where the catalog changes from day to day, the expected answer is
/// read from the catalog, not written in.
@Suite struct RealCatalogSearchTests {
    private func queue() throws -> DatabaseQueue {
        let path = RealCatalogMatchTests.catalogPath
        try #require(FileManager.default.fileExists(atPath: path), "no scripts/catalog.sqlite; download it from the catalog-latest release")
        var configuration = Configuration()
        configuration.readonly = true
        return try DatabaseQueue(path: path, configuration: configuration)
    }

    private func search(_ text: String, context: SearchContext = .browsing) throws -> [SearchHit] {
        let request = SearchRequest(text: text, context: context, filter: SearchFilter())
        return try queue().read { db in try CatalogSearch.search(db, request: request) }
    }

    private func names(_ hits: [SearchHit], _ count: Int) -> String {
        hits.prefix(count).map { "\($0.name) [\($0.setName)]" }.joined(separator: " | ")
    }

    // MARK: - The candidate cap

    /// "n" prefix-matches 5,766 products. The 200 best by bm25 were all
    /// Nidokings and Ninetales, so the Supporter card named N never became a
    /// candidate, and the exact-name tier had nothing to lift.
    @Test func aOneLetterNameIsNotLostUnderItsPrefixMatches() throws {
        let hits = try search("n")
        #expect(hits.first?.cleanName == "n", "top: \(names(hits, 3))")
    }

    /// The list sorts by value, so the most valuable match must reach the list.
    /// Before the fix, "rocket" lost a $2,400 Rocket's Mewtwo because 200
    /// cheaper cards had a better bm25 score.
    @Test(arguments: ["rocket", "pikachu", "eevee", "promo"])
    func theMostValuableMatchSurvivesABroadQuery(_ query: String) throws {
        let mostValuable = try queue().read { db in
            try Int.fetchOne(db, sql: """
                SELECT pr.productId FROM product_fts f JOIN price pr ON pr.productId = f.rowid
                WHERE product_fts MATCH ? ORDER BY pr.marketPriceCents DESC LIMIT 1
                """, arguments: [SearchQueryBuilder.ftsMatch(query)])
        }
        let id = try #require(mostValuable)
        let hits = try search(query)
        #expect(hits.contains { $0.productId == id }, "\(query): product \(id) is not in the results")
    }

    // MARK: - Words typed the way people type them

    /// The index splits "N's" into "n" and "s", so a typed "ns" matched
    /// nothing, fell to the trigram fallback, and listed other Reshirams.
    @Test func aPossessiveTypedWithoutTheApostropheStillFindsTheCard() throws {
        let reshiram = try search("ns reshiram")
        #expect(reshiram.prefix(3).allSatisfy { $0.name.hasPrefix("N's Reshiram") }, "\(names(reshiram, 3))")

        let clefairy = try search("lillies clefairy")
        #expect(clefairy.prefix(3).allSatisfy { $0.name.hasPrefix("Lillie's Clefairy") }, "\(names(clefairy, 3))")

        let mewtwo = try search("rockets mewtwo")
        #expect(mewtwo.prefix(3).allSatisfy { $0.name.contains("Rocket's Mewtwo") }, "\(names(mewtwo, 3))")

        let farfetchd = try search("farfetchd")
        #expect(farfetchd.prefix(3).allSatisfy { $0.name.hasPrefix("Farfetch'd") }, "\(names(farfetchd, 3))")
    }

    /// "1st Edition" is a printing, not a word in any card's name, so the
    /// query matched no name and the trigram fallback listed Union Arena cards.
    @Test(arguments: ["1st edition charizard", "first edition charizard"])
    func aPrintingWordThatIsNotInTheNameMeansThePrinting(_ query: String) throws {
        let hits = try search(query)
        let top = try #require(hits.first, "\(query): no results")
        #expect(top.cleanName == "charizard", "\(query): \(names(hits, 3))")
        let printings = try queue().read { db in
            try String.fetchAll(db, sql: "SELECT subTypeName FROM price WHERE productId = ?", arguments: [top.productId])
        }
        #expect(printings.contains { $0.hasPrefix("1st Edition") }, "\(query): top has \(printings)")
    }

    /// A product whose name carries the words must still be found by them.
    @Test func aPrintingWordInTheNameStillSearchesTheName() throws {
        let hits = try search("gym challenge 1st edition")
        #expect(hits.contains { $0.name == "Gym Challenge Booster Box [1st Edition]" }, "\(names(hits, 5))")
    }

    /// TCGplayer spells these out. Only two product names contain "ETB".
    @Test func commonShortFormsFindTheLongName() throws {
        let etb = try search("etb")
        #expect(etb.prefix(10).allSatisfy { $0.name.contains("Elite Trainer Box") || $0.name.contains("ETB") }, "\(names(etb, 5))")

        let etb151 = try search("151 etb")
        let top = try #require(etb151.first)
        #expect(top.name.contains("151") && top.name.contains("Elite Trainer Box"), "\(names(etb151, 3))")

        let pokeball = try search("pokeball")
        #expect(pokeball.prefix(5).allSatisfy { $0.name.contains("Poke Ball") }, "\(names(pokeball, 5))")

        let upc = try search("upc")
        #expect(upc.contains { $0.name.contains("Ultra Premium Collection") }, "\(names(upc, 5))")
    }

    // MARK: - Numbers after a name

    /// "25" also prefix-matches "025" totals and "25th Anniversary", and the
    /// value sort put a 007/025 card first.
    @Test func aNumberAfterTheNameMeansTheCollectorNumber() throws {
        let hits = try search("pikachu 25")
        #expect(hits.first?.numberNum == 25, "\(names(hits, 3))")
    }

    /// The same shape, but here the number is the set's name. A card from the
    /// 151 set must not lose to a card that happens to be numbered 151.
    @Test func aNumberThatNamesTheSetMeansTheSet() throws {
        let hits = try search("mew 151")
        #expect(hits.first?.setName.contains("151") == true, "\(names(hits, 3))")
    }

    // MARK: - What already worked must keep working

    @Test func queriesThatWorkedBeforeStillWork() throws {
        #expect(try search("charizard").first?.setName == "Base Set (Shadowless)")
        #expect(try search("base set charizard").first?.setName.hasPrefix("Base Set") == true)
        #expect(try search("n's reshiram").first?.name == "N's Reshiram")
        #expect(try search("umbreon alt art").first?.name == "Umbreon VMAX (Alternate Art Secret)")
        #expect(try search("tyranitar cosmos holo").first?.name.contains("Cosmos Holo") == true)
        let charizard151 = try search("charizard 151")
        #expect(charizard151.first.map { $0.name == "Charizard ex" && $0.setName.contains("151") } == true, "\(names(charizard151, 3))")
        #expect(try search("125/197").first?.number == "125/197")
        // A typo still falls back to trigrams.
        #expect(try search("charzard").first?.cleanName.hasPrefix("charizard") == true)
    }

    // MARK: - Speed

    /// The broadest prefixes are the slowest queries the field can send. The
    /// field searches on every keystroke after a 150 ms debounce.
    @Test(arguments: ["n", "p", "promo", "pikachu", "charizard ex"])
    func broadQueriesStayFast(_ query: String) throws {
        let queue = try queue()
        let request = SearchRequest(text: query, context: .browsing, filter: SearchFilter())
        _ = try queue.read { db in try CatalogSearch.search(db, request: request) }
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            _ = try queue.read { db in try CatalogSearch.search(db, request: request) }
        }
        print("search \(query): \(elapsed)")
        #expect(elapsed < .milliseconds(250), "\(query) took \(elapsed)")
    }
}
