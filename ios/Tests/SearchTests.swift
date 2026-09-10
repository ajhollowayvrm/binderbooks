import Foundation
import GRDB
import Testing
@testable import CardTracker

// MARK: - Fixture

/// A tiny catalog with the real schema from catalog/build_catalog.py.
private enum Fixture {
    struct Product {
        var id: Int
        var groupId: Int
        var categoryId: Int
        var name: String
        var number: String?
        var rarity: String?
        var sealed: Bool
        var prices: [(String, Int)]
    }

    static let products: [Product] = [
        Product(id: 1, groupId: 100, categoryId: 3, name: "Charizard ex", number: "125/197", rarity: "Double Rare", sealed: false, prices: [("Holofoil", 4_500)]),
        Product(id: 2, groupId: 101, categoryId: 3, name: "Charizard", number: "4/102", rarity: "Holo Rare", sealed: false, prices: [("Holofoil", 30_000), ("1st Edition Holofoil", 900_000)]),
        Product(id: 3, groupId: 100, categoryId: 3, name: "Charmander", number: "026/197", rarity: "Common", sealed: false, prices: [("Normal", 10), ("Reverse Holofoil", 40)]),
        Product(id: 4, groupId: 102, categoryId: 3, name: "Legendary Warriors Premium Collection", number: nil, rarity: nil, sealed: true, prices: [("Normal", 5_999)]),
        Product(id: 5, groupId: 102, categoryId: 3, name: "Code Card - Legendary Warriors Premium Collection", number: nil, rarity: nil, sealed: false, prices: []),
        Product(id: 6, groupId: 100, categoryId: 3, name: "Obsidian Flames Booster Pack", number: nil, rarity: nil, sealed: true, prices: [("Normal", 450)]),
        Product(id: 7, groupId: 103, categoryId: 85, name: "Umbreon", number: "020/076", rarity: "Common", sealed: false, prices: [("Normal", 120)]),
        Product(id: 8, groupId: 104, categoryId: 63, name: "Pristimon", number: "BT26-052 C", rarity: "Common", sealed: false, prices: [("Normal", 15)]),
        Product(id: 9, groupId: 100, categoryId: 3, name: "Pidgeot ex", number: "164/197", rarity: "Ultra Rare", sealed: false, prices: [("Holofoil", 800)]),
    ]

    static func make() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE category (categoryId INTEGER PRIMARY KEY, name TEXT NOT NULL, displayName TEXT NOT NULL);
            CREATE TABLE cardSet (groupId INTEGER PRIMARY KEY, categoryId INTEGER NOT NULL, name TEXT NOT NULL, abbreviation TEXT, publishedOn TEXT);
            CREATE TABLE product (productId INTEGER PRIMARY KEY, groupId INTEGER NOT NULL, categoryId INTEGER NOT NULL, name TEXT NOT NULL,
                cleanName TEXT NOT NULL, imageUrl TEXT, number TEXT, numberNum INTEGER, setTotal INTEGER, setCode TEXT, rarity TEXT, cardType TEXT,
                isSealed INTEGER NOT NULL DEFAULT 0, printingCount INTEGER NOT NULL DEFAULT 1);
            CREATE TABLE price (productId INTEGER NOT NULL, subTypeName TEXT NOT NULL, marketPriceCents INTEGER, lowPriceCents INTEGER,
                midPriceCents INTEGER, highPriceCents INTEGER, directLowPriceCents INTEGER, asOf TEXT NOT NULL, PRIMARY KEY (productId, subTypeName));
            CREATE VIRTUAL TABLE product_fts USING fts5(name, number, setName, content='', tokenize='unicode61 remove_diacritics 2', prefix='2 3 4');
            CREATE VIRTUAL TABLE product_trigram USING fts5(name, number, content='', tokenize='trigram');
            INSERT INTO category VALUES (3, 'Pokemon', 'Pokemon'), (85, 'Pokemon Japan', 'Pokemon Japan'), (63, 'Digimon Card Game', 'Digimon Card Game');
            INSERT INTO cardSet VALUES
                (100, 3, 'SV03: Obsidian Flames', 'OBF', '2023-08-11T00:00:00'),
                (101, 3, 'Base Set', 'BS', '1999-01-09T00:00:00'),
                (102, 3, 'SWSH: Sword & Shield Promo Cards', 'PR-SW', '2020-02-07T00:00:00'),
                (103, 85, 'M6: Storm Emeralda', 'M6', '2026-08-01T00:00:00'),
                (104, 63, 'Timeless Bonds', 'BT-26', '2026-07-01T00:00:00');
            """)
            let setNames = [100: "SV03: Obsidian Flames", 101: "Base Set", 102: "SWSH: Sword & Shield Promo Cards", 103: "M6: Storm Emeralda", 104: "Timeless Bonds"]
            for p in products {
                let parsed = CollectorNumber.parse(p.number)
                try db.execute(
                    sql: "INSERT INTO product VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, NULL, ?, ?)",
                    arguments: [p.id, p.groupId, p.categoryId, p.name, NameCleaner.clean(p.name), p.number, parsed.numberNum, parsed.setTotal, parsed.setCode, p.rarity, p.sealed ? 1 : 0, max(1, p.prices.count)]
                )
                try db.execute(sql: "INSERT INTO product_fts(rowid, name, number, setName) VALUES (?, ?, ?, ?)", arguments: [p.id, p.name, p.number ?? "", setNames[p.groupId]!])
                try db.execute(sql: "INSERT INTO product_trigram(rowid, name, number) VALUES (?, ?, ?)", arguments: [p.id, p.name, p.number ?? ""])
                for (subType, cents) in p.prices {
                    try db.execute(sql: "INSERT INTO price VALUES (?, ?, ?, ?, ?, ?, NULL, '2026-09-10')", arguments: [p.id, subType, cents, cents, cents, cents])
                }
            }
        }
        return queue
    }

    static func search(_ text: String, context: SearchContext = .browsing, filter: SearchFilter = SearchFilter()) throws -> [SearchHit] {
        let queue = try make()
        let request = SearchRequest(text: text, context: context, filter: filter)
        return try queue.read { db in try CatalogSearch.search(db, request: request) }
    }
}

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
        #expect(SearchQueryBuilder.ftsMatch("legendary warriors") == "\"legendary\"* \"warriors\"*")
        #expect(SearchQueryBuilder.ftsMatch("  char ") == "\"char\"*")
        #expect(SearchQueryBuilder.ftsMatch("farfetch'd \"quoted\"") == "\"farfetch'd\"* \"quoted\"*")
        #expect(SearchQueryBuilder.ftsMatch("   ") == nil)
    }

    @Test func trigramOrsTheQueryTrigrams() {
        #expect(SearchQueryBuilder.trigramMatch("charz") == "\"cha\" OR \"har\" OR \"arz\"")
        #expect(SearchQueryBuilder.trigramMatch("ab") == nil)
        #expect(SearchQueryBuilder.trigramMatch("aaaa") == "\"aaa\"")
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
    private func hit(_ id: Int, name: String, number: String? = nil, sealed: Bool = false, published: String? = nil) -> SearchHit {
        let parsed = CollectorNumber.parse(number)
        return SearchHit(
            productId: id, groupId: 0, categoryId: 3, name: name, cleanName: NameCleaner.clean(name), setName: "",
            number: number, numberNum: parsed.numberNum, setTotal: parsed.setTotal, setCode: parsed.setCode,
            rarity: nil, isSealed: sealed, printingCount: 1, imageUrl: nil, publishedOn: published,
            minMarketCents: nil, maxMarketCents: nil
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
        #expect(try Fixture.search("legendary warriors", context: .buying).first?.productId == 4)
        #expect(try Fixture.search("legendary warriors", context: .intake).first?.productId == 5)
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

    @Test func rowsCarryPriceAndSetData() throws {
        let hit = try #require(try Fixture.search("charizard").first)
        #expect(hit.setName == "Base Set")
        #expect(hit.minMarketCents == 30_000)
        #expect(hit.maxMarketCents == 900_000)
        #expect(hit.priceLabel == "from $300.00")
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
    @Test func browsingASetListsItByNumber() async throws {
        let queue = try Fixture.make()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite").path
        try queue.backup(to: DatabaseQueue(path: path))
        let catalog = try CatalogDatabase(path: path)
        let search = CatalogSearch(database: catalog)

        var filter = SearchFilter(); filter.groupId = 100
        let hits = try await search.search(SearchRequest(text: "", context: .browsing, filter: filter))
        #expect(hits.map(\.productId) == [3, 1, 9, 6])

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
