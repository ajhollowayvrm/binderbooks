import Foundation
import GRDB
import Testing
@testable import BinderBooks

// MARK: - Pure parts

@Suite struct CollectorNumberTests {
    func check(_ raw: String, _ num: Int?, _ total: Int? = nil, _ code: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(CollectorNumber.parse(raw) == CollectorNumber(numberNum: num, setTotal: total, setCode: code), sourceLocation: sourceLocation)
    }

    @Test func mirrorsThePythonParser() {
        check("114/084", 114, 84)
        check("226/197", 226, 197)
        check("001/M-P", 1, nil, "M-P")
        check("007/PPP", 7, nil, "PPP")
        check("SWSH083", 83, nil, "SWSH")
        check("SVP 200", 200, nil, "SVP")
        check("XY67a", 67, nil, "XY")
        check("073", 73)
        check("BT26-052 C", 52, nil, "BT26")
        check("UE10BT/AOT-1-007", 7, nil, "UE10BT")
        check("UEX07BT/AOT-2-AP01", 1, nil, "UEX07BT")
        check("073/076 / 074/076", 73, 76)
        check("SV-P", nil)
        check("", nil)
    }

    @Test func looksLikeNumber() {
        #expect(CollectorNumber.looksLikeNumber("114/084"))
        #expect(CollectorNumber.looksLikeNumber("swsh083"))
        #expect(CollectorNumber.looksLikeNumber("BT26-052"))
        #expect(CollectorNumber.looksLikeNumber("073"))
        #expect(!CollectorNumber.looksLikeNumber("10"))
        #expect(!CollectorNumber.looksLikeNumber("charizard"))
        #expect(!CollectorNumber.looksLikeNumber("ex"))
    }

    @Test func cleanNameMirrorsThePythonRule() {
        #expect(NameCleaner.clean("Pokémon Center Lady") == "pokemon center lady")
        #expect(NameCleaner.clean("Farfetch'd") == "farfetch d")
        #expect(NameCleaner.clean("Stellar Crown Build & Battle Box") == "stellar crown build and battle box")
        #expect(NameCleaner.clean("  Mr.   Mime  ") == "mr mime")
        #expect(NameCleaner.clean("Charizard ex") == "charizard ex")
    }
}

@Suite struct QueryBuilderTests {
    @Test func ftsQuotesEveryTokenAsAPrefix() {
        #expect(SearchQueryBuilder.ftsMatch("legendary box") == "\"legendary\"* AND \"box\"*")
        #expect(SearchQueryBuilder.ftsMatch("  char ") == "\"char\"*")
        #expect(SearchQueryBuilder.ftsMatch("farfetch'd \"quoted\"") == "\"farfetch'd\"* AND \"quoted\"*")
        #expect(SearchQueryBuilder.ftsMatch("   ") == nil)
    }

    @Test func ftsOffersTheCatalogsSpellingOfAToken() {
        // A possessive with no apostrophe. The index holds "N's" as "n" "s".
        #expect(SearchQueryBuilder.ftsMatch("ns reshiram") == "(\"ns\"* OR \"n s\"*) AND \"reshiram\"*")
        #expect(SearchQueryBuilder.ftsMatch("n's") == "\"n's\"*")
        // A short form TCGplayer spells out.
        #expect(SearchQueryBuilder.ftsMatch("ETB") == "(\"ETB\"* OR \"elite trainer box\"*)")
        #expect(SearchQueryBuilder.ftsMatch("farfetchd") == "(\"farfetchd\"* OR \"farfetch d\"*)")
        // A short number, which prints with leading zeros.
        #expect(SearchQueryBuilder.ftsMatch("pikachu 25") == "\"pikachu\"* AND (\"25\"* OR \"025\"*)")
        #expect(SearchQueryBuilder.ftsMatch("151") == "\"151\"*")
    }

    @Test func printingWordsSplitOffTheQuery() {
        typealias Q = SearchQueryBuilder.PrintingQualifier
        #expect(SearchQueryBuilder.printingQualifier("1st edition charizard") == Q(remainder: "charizard", printing: "1st Edition"))
        #expect(SearchQueryBuilder.printingQualifier("First Ed Charizard") == Q(remainder: "Charizard", printing: "1st Edition"))
        #expect(SearchQueryBuilder.printingQualifier("charizard unlimited") == Q(remainder: "charizard", printing: "Unlimited"))
        // Nothing left to search, or no printing word at all.
        #expect(SearchQueryBuilder.printingQualifier("1st edition") == nil)
        #expect(SearchQueryBuilder.printingQualifier("charizard") == nil)
        #expect(SearchQueryBuilder.printingQualifier("edition box") == nil)
    }

    @Test func trigramOrsTheQueryTrigrams() {
        #expect(SearchQueryBuilder.trigramMatch("charz") == "\"cha\" OR \"har\" OR \"arz\"")
        #expect(SearchQueryBuilder.trigramMatch("ab") == nil)
        #expect(SearchQueryBuilder.trigramMatch("aaaa") == "\"aaa\"")
    }

    @Test func trigramAndsEachTokenSeparately() {
        // Each word gets its own OR group. A row must match every group, so a
        // second word can't pull in rows that only share a trigram with it.
        #expect(SearchQueryBuilder.trigramMatch("bin pro") == "(\"bin\") AND (\"pro\")")
        #expect(SearchQueryBuilder.trigramMatch("ab pro") == "\"pro\"")
    }
}

@Suite struct MoneyTests {
    @Test func formatsCentsWithTwoDecimals() {
        #expect(1_234_56.asCurrency == "$1,234.56")
        #expect(5.asCurrency == "$0.05")
        #expect(0.asCurrency == "$0.00")
        #expect(900_000.asCurrency == "$9,000.00")
    }

    @Test func parsesTypedAmounts() {
        #expect(Money.cents(from: "12.34") == 1234)
        #expect(Money.cents(from: "$1,000") == 100_000)
        #expect(Money.cents(from: "0.5") == 50)
        #expect(Money.cents(from: "1.005") == nil)
        #expect(Money.cents(from: "") == nil)
    }
}

@Suite struct RankerTests {
    private func hit(
        _ id: Int, name: String, number: String? = nil, sealed: Bool = false,
        published: String? = nil, market: Int? = nil, set: String = ""
    ) -> SearchHit {
        let parsed = CollectorNumber.parse(number)
        return SearchHit(
            productId: id, groupId: 0, categoryId: 3, name: name, cleanName: NameCleaner.clean(name), setName: set,
            number: number, numberNum: parsed.numberNum, setTotal: parsed.setTotal, setCode: parsed.setCode,
            rarity: nil, isSealed: sealed, printingCount: 1, imageUrl: nil, publishedOn: published,
            minMarketCents: market, maxMarketCents: market
        )
    }

    @Test func exactNumberBeatsExactNameBeatsBm25() {
        let request = SearchRequest(text: "125/197", context: .browsing, filter: SearchFilter())
        let byNumber = SearchRanker.Candidate(hit: hit(1, name: "Charizard ex", number: "125/197"), ftsRank: -1)
        let byName = SearchRanker.Candidate(hit: hit(2, name: "125/197", number: "001/001"), ftsRank: -1)
        let plain = SearchRanker.Candidate(hit: hit(3, name: "Something", number: "125/198"), ftsRank: -50)
        let ranked = SearchRanker.rank([plain, byName, byNumber], request: request)
        #expect(ranked.map(\.productId) == [1, 2, 3])
    }

    @Test func contextBoostsSealedWhenBuyingAndSinglesWhenScanning() {
        let sealed = SearchRanker.Candidate(hit: hit(4, name: "Legendary Warriors Premium Collection", sealed: true), ftsRank: -5)
        let single = SearchRanker.Candidate(hit: hit(5, name: "Code Card - Legendary Warriors Premium Collection"), ftsRank: -5)
        let buying = SearchRequest(text: "legendary warriors", context: .buying, filter: SearchFilter())
        let scanning = SearchRequest(text: "legendary warriors", context: .scanning, filter: SearchFilter())
        #expect(SearchRanker.rank([single, sealed], request: buying).first?.productId == 4)
        #expect(SearchRanker.rank([sealed, single], request: scanning).first?.productId == 5)
    }

    @Test func newerSetBreaksTies() {
        let old = SearchRanker.Candidate(hit: hit(1, name: "Pikachu", published: "1999-01-09T00:00:00"), ftsRank: -3)
        let new = SearchRanker.Candidate(hit: hit(2, name: "Pikachu", published: "2026-09-01T00:00:00"), ftsRank: -3)
        let request = SearchRequest(text: "pika", context: .browsing, filter: SearchFilter())
        #expect(SearchRanker.rank([old, new], request: request).first?.productId == 2)
    }

    @Test func valueOutranksBm25() {
        let cheapButRelevant = SearchRanker.Candidate(hit: hit(1, name: "Pikachu", market: 100), ftsRank: -1)
        let expensive = SearchRanker.Candidate(hit: hit(2, name: "Pikachu VMAX", market: 90_000), ftsRank: -50)
        let request = SearchRequest(text: "pika", context: .browsing, filter: SearchFilter())
        #expect(SearchRanker.rank([cheapButRelevant, expensive], request: request).map(\.productId) == [2, 1])
    }

    @Test func pricelessHitsSortLast() {
        let priced = SearchRanker.Candidate(hit: hit(1, name: "Pikachu", market: 5), ftsRank: -50)
        let noPrice = SearchRanker.Candidate(hit: hit(2, name: "Pikachu V", market: nil), ftsRank: -1)
        let request = SearchRequest(text: "pika", context: .browsing, filter: SearchFilter())
        #expect(SearchRanker.rank([noPrice, priced], request: request).map(\.productId) == [1, 2])
    }

    @Test func exactMatchesStillOutrankValue() {
        let exact = SearchRanker.Candidate(hit: hit(1, name: "Pikachu", number: "025/165", market: 100), ftsRank: -1)
        let expensive = SearchRanker.Candidate(hit: hit(2, name: "Pikachu VMAX", number: "044/185", market: 90_000), ftsRank: -1)
        let byNumber = SearchRequest(text: "025/165", context: .browsing, filter: SearchFilter())
        #expect(SearchRanker.rank([expensive, exact], request: byNumber).first?.productId == 1)
        let byName = SearchRequest(text: "pikachu", context: .browsing, filter: SearchFilter())
        #expect(SearchRanker.rank([expensive, exact], request: byName).first?.productId == 1)

    }

    @Test func aNumberInANameOutranksValue() {
        // "pikachu 25": the card numbered 25 beats a dearer card whose total is 025.
        let numbered = SearchRanker.Candidate(hit: hit(1, name: "Pikachu", number: "025/165", market: 100), ftsRank: -1)
        let byTotal = SearchRanker.Candidate(hit: hit(2, name: "_____'s Pikachu", number: "007/025", market: 19_500), ftsRank: -1)
        let pikachu = SearchRequest(text: "pikachu 25", context: .browsing, filter: SearchFilter())
        #expect(SearchRanker.rank([byTotal, numbered], request: pikachu).map(\.productId) == [1, 2])

        // "mew 151": the number is the set's name, and a card from that set
        // ties with a card numbered 151, so value decides between them. A
        // dearer card that matches neither comes after both.
        let fromTheSet = SearchRanker.Candidate(hit: hit(3, name: "Mew ex", number: "205/165", market: 21_000, set: "SV2a: Pokemon Card 151"), ftsRank: -1)
        let number151 = SearchRanker.Candidate(hit: hit(4, name: "Mew ex", number: "151/165", market: 4_490, set: "Prize Pack Series Cards"), ftsRank: -1)
        let neither = SearchRanker.Candidate(hit: hit(5, name: "Mew", number: "010/102", market: 50_000, set: "Base Set"), ftsRank: -1)
        let mew = SearchRequest(text: "mew 151", context: .browsing, filter: SearchFilter())
        #expect(SearchRanker.rank([neither, number151, fromTheSet], request: mew).map(\.productId) == [3, 4, 5])

        // One token alone is a name or a number, never both. "pika", not
        // "pikachu": hit 1 is named exactly Pikachu, and the exact-name tier
        // would lift it for its own reason.
        let bare = SearchRequest(text: "pika", context: .browsing, filter: SearchFilter())
        #expect(SearchRanker.rank([numbered, byTotal], request: bare).map(\.productId) == [2, 1])
    }

    @Test func trigramOnlyHitsRankBelowFtsHits() {
        let fts = SearchRanker.Candidate(hit: hit(1, name: "Charmander"), ftsRank: -1)
        let tri = SearchRanker.Candidate(hit: hit(2, name: "Charizard"), trigramRank: -8)
        let request = SearchRequest(text: "charm", context: .browsing, filter: SearchFilter())
        #expect(SearchRanker.rank([tri, fts], request: request).first?.productId == 1)
    }
}

// MARK: - End to end on the fixture

@Suite struct CatalogSearchTests {
    @Test func prefixSearchFindsTheCharizards() throws {
        let names = try Fixture.search("char").map(\.name)
        #expect(names.contains("Charizard ex"))
        #expect(names.contains("Charizard"))
        #expect(names.contains("Charmander"))
        #expect(!names.contains("Umbreon"))
    }

    @Test func exactNameRanksFirst() throws {
        #expect(try Fixture.search("charizard").first?.name == "Charizard")
        #expect(try Fixture.search("charizard ex").first?.name == "Charizard ex")
    }

    @Test func typoFallsBackToTrigrams() throws {
        let hits = try Fixture.search("charzard")
        #expect(hits.first?.name.hasPrefix("Charizard") == true)
    }

    @Test func onlyEmptyPathAFallsBackToTrigrams() throws {
        // "Legendary Warriors" only shows up as a promo card via its set
        // name, so path A already finds it directly. Path B must not run at
        // all here, so nothing dilutes the two real hits with unrelated
        // trigram noise (a query for a promo card must not return every
        // promo card in the catalog).
        let ids = try Fixture.search("legendary promo").map(\.productId)
        #expect(Set(ids) == [4, 5])
    }

    @Test func trigramFallbackStillAndsEachTypoedWord() throws {
        // Both words are misspelled, so path A finds nothing and path B
        // fires. It must still require both words to fuzzy-match, so
        // "Professional Grade Toploader" (which shares no trigram with
        // either misspelled word) does not sneak in as a false positive.
        let ids = try Fixture.search("legendairy colection").map(\.productId)
        #expect(Set(ids) == [4, 5])
    }

    @Test func collectorNumberIsExact() throws {
        #expect(try Fixture.search("125/197").first?.productId == 1)
        #expect(try Fixture.search("4/102").first?.productId == 2)
        #expect(try Fixture.search("BT26-052").first?.productId == 8)
        #expect(try Fixture.search("020/076").first?.productId == 7)
    }

    @Test func setNameIsSearchable() throws {
        let ids = try Fixture.search("obsidian").map(\.productId)
        #expect(Set(ids) == [1, 3, 6, 9])
    }

    @Test func buyingBoostsTheSealedProduct() throws {
        // Compare the pair, not the first row. The context boost is a
        // statement about these two products only, not about the full list.
        func rank(_ context: SearchContext, _ id: Int) throws -> Int {
            let ids = try Fixture.search("legendary warriors", context: context).map(\.productId)
            return try #require(ids.firstIndex(of: id))
        }
        #expect(try rank(.buying, 4) < rank(.buying, 5))
        #expect(try rank(.intake, 5) < rank(.intake, 4))
    }

    @Test func kindFilterNarrows() throws {
        var sealed = SearchFilter(); sealed.kind = .sealed
        #expect(try Fixture.search("obsidian", filter: sealed).map(\.productId) == [6])
        var singles = SearchFilter(); singles.kind = .singles
        #expect(!(try Fixture.search("legendary", filter: singles).contains { $0.isSealed }))
    }

    @Test func categoryFilterNarrows() throws {
        var japan = SearchFilter(); japan.categoryIds = [85]
        #expect(try Fixture.search("umb", filter: japan).map(\.productId) == [7])
        #expect(try Fixture.search("char", filter: japan).isEmpty)
    }

    @Test func resultsComeBackByValueDescending() throws {
        // Charizard tops $9,000 on its first edition printing, Charizard ex is
        // $45, Charmander is $0.40.
        #expect(try Fixture.search("char").map(\.productId) == [2, 1, 3])
    }

    @Test func rowsCarryPriceAndSetData() throws {
        let hit = try #require(try Fixture.search("charizard").first)
        #expect(hit.setName == "Base Set")
        #expect(hit.minMarketCents == 30_000)
        #expect(hit.maxMarketCents == 900_000)
        #expect(hit.priceLabel == "$9,000.00")
        #expect(hit.printingCount == 2)
    }

    @Test func emptyQueryReturnsNothingWithoutAFilter() throws {
        #expect(try Fixture.search("").isEmpty)
        #expect(try Fixture.search("   ").isEmpty)
    }

    @Test func tooShortForTrigramsStillSearchesPrefixes() throws {
        #expect(!(try Fixture.search("ch").isEmpty))
    }

    @Test func operatorsInTheQueryDoNotThrow() throws {
        _ = try Fixture.search("char AND OR NOT (\"")
        _ = try Fixture.search("farfetch'd")
        _ = try Fixture.search("*")
        _ = try Fixture.search("125/")
    }
}

@Suite struct BrowseAndFacetTests {
    @Test func browsingASetListsItByValue() async throws {
        let queue = try Fixture.make()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite").path
        try queue.backup(to: DatabaseQueue(path: path))
        let catalog = try CatalogDatabase(path: path)
        let search = CatalogSearch(database: catalog)

        var filter = SearchFilter(); filter.groupId = 100
        let hits = try await search.search(SearchRequest(text: "", context: .browsing, filter: filter))
        // Charizard ex $45, Pidgeot ex $8, the booster pack $4.50, Charmander $0.40.
        #expect(hits.map(\.productId) == [1, 9, 6, 3])

        let sets = try await search.sets()
        #expect(sets.first?.name == "M6: Storm Emeralda")
        #expect(sets.first { $0.groupId == 100 }?.productCount == 4)

        let categories = try await search.categories()
        #expect(categories.map(\.chipTitle) == ["Pokémon", "Digimon", "Japan"])

        let detail = try #require(try await search.detail(productId: 2))
        #expect(detail.prices.count == 2)
        #expect(detail.categoryName == "Pokemon")
        #expect(detail.tcgplayerURL.absoluteString == "https://www.tcgplayer.com/product/2")

        let ordered = try await search.hits(ids: [9, 1])
        #expect(ordered.map(\.productId) == [9, 1])
        try catalog.close()
    }
}
