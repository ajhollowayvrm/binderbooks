import Foundation
import GRDB
import Testing
@testable import BinderBooks

/// Simplified Chinese cards in a scan session.
///
/// The fixture's Chinese cards sit beside its English ones the way
/// `ChineseCatalog` merges them. Charmander carries 026/197 in both catalogs,
/// which is the case that matters: an English answer is always on offer for a
/// Chinese card, and it always carries the wrong price.
@Suite struct ChineseScanTests {
    private func match(_ observation: ScanObservation, language: ScanLanguage?) throws -> MatchResult {
        let queue = try Fixture.make(chinese: true)
        return try queue.read { db in
            try CardMatcher.match(db, observation: observation, bias: [], defaultPrinting: nil, language: language)
        }
    }

    private func observation(number: String?, name: String?) -> ScanObservation {
        var observation = ScanObservation(number: number)
        if let name {
            observation.name = name
            observation.nameCandidates = [name]
            observation.sawJapaneseText = FrameInterpreter.isJapanese(name)
        }
        return observation
    }

    /// A Gem Pack card prints slot 01, art 01 of 7 as "0101/07". Four digits
    /// before the slash, which no English pattern reads.
    @Test func theGemPackNumberReadsOffTheCard() {
        #expect(FrameInterpreter.number(in: ["小火马", "0101/07 ●"])?.value == "0101/07")
        #expect(CollectorNumber.parse("0101/07") == CollectorNumber(numberNum: 101, setTotal: 7))
    }

    /// A Chinese card prints its rarity letter against the total, and Vision
    /// reads the two as one word.
    @Test func theRarityLetterAfterTheTotalIsNotPartOfTheNumber() {
        #expect(FrameInterpreter.number(in: ["列阵兵", "071/129C"])?.value == "071/129")
        #expect(FrameInterpreter.number(in: ["188/208R"])?.value == "188/208")
        #expect(FrameInterpreter.number(in: ["2202/07C"])?.value == "2202/07")
        // A Gem Pack total is two digits. The ◎ after it read as a 4.
        #expect(FrameInterpreter.number(in: ["1302/074"])?.value == "1302/07")
    }

    @Test func aTwoCharacterChineseNameIsAName() {
        #expect(FrameInterpreter.isPlausibleName("耿鬼"))
        #expect(!FrameInterpreter.isPlausibleName("HP"))
    }

    @Test func aChineseSessionReadsChineseAndLooksInTheChineseCatalog() {
        #expect(ScanLanguage.chineseSimplified.recognitionLanguages == ["zh-Hans", "en"])
        #expect(ScanLanguage.chineseSimplified.categoryId == TCGCategory.pokemonChinese)
        #expect(CardMatcher.artScope(for: .chineseSimplified) == .only(TCGCategory.pokemonChinese))
        #expect(CardMatcher.artScope(for: .english) == .excluding(TCGCategory.pokemonChinese))
        #expect(CardMatcher.artScope(for: nil) == .excluding(TCGCategory.pokemonChinese))
    }

    @Test func theChineseNameAndTheNumberAgreeOnTheGemPackCard() throws {
        let result = try match(observation(number: "0101/07", name: "小火马"), language: .chineseSimplified)
        #expect(result.productId == Fixture.chinesePonyta)
        #expect(result.confidence == .certain)
    }

    /// The art number is the money: art 7 of this Ponyta sells for a hundred
    /// times art 1.
    @Test func theArtNumberPicksTheArt() throws {
        let result = try match(observation(number: "0107/07", name: "小火马"), language: .chineseSimplified)
        #expect(result.productId == Fixture.chinesePonytaArtRare)
    }

    @Test func onlyAnExactChineseNameBecomesAnEnglishName() throws {
        let names = try Fixture.make(chinese: true).read { db in
            (
                try CardMatcher.englishName(db, printed: "溜溜糖球"),
                try CardMatcher.englishName(db, printed: "溜溜糖"),
                try CardMatcher.englishName(db, printed: "Surskit")
            )
        }
        #expect(names.0 == "Surskit")
        #expect(names.1 == nil)
        #expect(names.2 == nil)
    }

    /// Vision read Cacturne as 夢歌仙人掌, with the Traditional 夢. The catalog
    /// holds 梦歌仙人掌. The Traditional form still finds the card.
    @Test func aTraditionalCharacterStillFindsTheSimplifiedName() throws {
        let name = try Fixture.make(chinese: true).read { db in
            try CardMatcher.englishName(db, printed: "小火龍")
        }
        #expect(name == "Charmander")
    }

    @Test func aChineseSessionTakesTheChineseCard() throws {
        let result = try match(observation(number: "026/197", name: "小火龙"), language: .chineseSimplified)
        #expect(result.productId == Fixture.chineseCharmander)
        #expect(result.candidates.allSatisfy { $0.categoryId == TCGCategory.pokemonChinese })
    }

    @Test func anEnglishSessionNeverOffersTheChineseCard() throws {
        let result = try match(observation(number: "026/197", name: "Charmander"), language: .english)
        #expect(result.productId == 3)
        #expect(!result.candidates.contains { $0.categoryId == TCGCategory.pokemonChinese })
    }

    /// 125/197 is an English Charizard ex, and no Chinese card carries it.
    /// Assigning the English card would log a Chinese card at an English price.
    @Test func aChineseSessionNeverAssignsAnEnglishCard() throws {
        let result = try match(observation(number: "125/197", name: nil), language: .chineseSimplified)
        #expect(result.productId == nil)
        #expect(result.candidates.isEmpty)
    }

    /// The build can get a total wrong by one. Terastal Gathering prints 208,
    /// and the catalog held 207. An English session keeps the exact total.
    @Test func aTotalWrongByOneStillFindsTheChineseCard() throws {
        let chinese = try match(observation(number: "026/198", name: nil), language: .chineseSimplified)
        #expect(chinese.productId == Fixture.chineseCharmander)
        let english = try match(observation(number: "026/198", name: nil), language: .english)
        #expect(english.productId == nil)
    }

    /// A start deck card prints 330/414, and the catalog holds 330 with no total.
    @Test func aCardWithNoTotalInTheCatalogIsFoundByItsNumber() throws {
        let result = try match(observation(number: "330/414", name: nil), language: .chineseSimplified)
        #expect(result.productId == Fixture.chineseMeowth)
    }

    /// PikaQian lists the Poké Ball printing as its own card, and the Mac build
    /// names it the way TCGplayer does, so the pattern family asks as it does
    /// for an English card.
    @Test func thePatternPrintingsOfAChineseCardAsk() throws {
        let result = try match(observation(number: "001/128", name: "溜溜糖球"), language: .chineseSimplified)
        #expect(result.confidence == .uncertain)
        #expect(Set(result.candidates.prefix(2).map(\.productId)) == [Fixture.chineseSurskit, Fixture.chineseSurskitPokeBall])
    }

    @Test func theArtworkShortlistStaysInTheSessionsCatalog() {
        let picture = Fixture.artDescriptor(seed: 0x51DE)
        let norm = picture.reduce(Float(0)) { $0 + Float($1) * Float($1) }.squareRoot()
        let art = ArtIndex(
            productIds: [16, Int32(Fixture.chineseCharmander)],
            values: picture + picture,
            norms: [norm, norm],
            categoryIds: [Int32(TCGCategory.pokemon), Int32(TCGCategory.pokemonChinese)]
        )
        #expect(art.nearest(to: picture, scope: .only(TCGCategory.pokemonChinese)).map(\.productId) == [Fixture.chineseCharmander])
        #expect(art.nearest(to: picture, scope: .excluding(TCGCategory.pokemonChinese)).map(\.productId) == [16])
        #expect(art.nearest(to: picture).count == 2)
    }

    @Test func aChineseCardStaysOutOfTheTCGplayerFile() {
        let hit = SearchHit(
            productId: Fixture.chinesePonyta, groupId: Fixture.chineseGemPack, categoryId: TCGCategory.pokemonChinese,
            name: "Ponyta", cleanName: "ponyta", setName: "Gem Pack Vol 4", isSealed: false, printingCount: 1
        )
        let card = OwnedCard(productId: Fixture.chinesePonyta, printing: "Holofoil", condition: CardCondition.nearMint.rawValue, confidence: .manual)
        #expect(TCGplayerListingExport.skipReason(for: card, hit: hit) == .notOnTCGplayer)
    }
}

/// The merge that puts the Chinese catalog into the live one, on real files.
@Suite struct ChineseCatalogMergeTests {
    struct Card {
        var id: Int
        var name: String
        var local: String
        var number: String
    }

    static let ponyta = Card(id: Fixture.chinesePonyta, name: "Ponyta", local: "小火马", number: "0101/07")
    static let surskit = Card(id: Fixture.chineseSurskit, name: "Surskit", local: "溜溜糖球", number: "001/128")

    private static func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The shared fixture on disk, with no Chinese cards: a downloaded catalog.
    private static func catalogFile(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("catalog.sqlite")
        try Fixture.make(path: url.path).close()
        return url
    }

    /// A file in the shape catalog/build_chinese.py writes.
    /// `salesChecked` lists the cards with eBay sales, the way a build that
    /// asked PikaQian writes them. Nil is a build that did not ask.
    private static func chineseFile(in dir: URL, named name: String, builtAt: String, cards: [Card], salesChecked: [Int]? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: Fixture.ddl)
            try db.execute(sql: """
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE productArt (productId INTEGER PRIMARY KEY, descriptor BLOB NOT NULL);
            CREATE TABLE productLocalName (productId INTEGER PRIMARY KEY, localName TEXT NOT NULL);
            CREATE TABLE ftsText (productId INTEGER PRIMARY KEY, name TEXT NOT NULL, number TEXT NOT NULL, setName TEXT NOT NULL);
            """)
            try db.execute(
                sql: "INSERT INTO category VALUES (?, 'Pokemon Simplified Chinese', 'Pokemon Simplified Chinese')",
                arguments: [TCGCategory.pokemonChinese]
            )
            try db.execute(
                sql: "INSERT INTO cardSet VALUES (?, ?, 'Gem Pack Vol 4', 'CBB4C', '2026-02-06')",
                arguments: [Fixture.chineseGemPack, TCGCategory.pokemonChinese]
            )
            let meta: [(String, String)] = [
                ("schemaVersion", String(supportedCatalogSchemaVersion)),
                ("kind", ChineseCatalog.kind),
                ("formatVersion", String(ChineseCatalog.formatVersion)),
                ("builtAt", builtAt),
                ("sourceDate", String(builtAt.prefix(10))),
                ("productCount", String(cards.count)),
                ("categories", "[]"),
                ("artFormatVersion", String(CardArtDescriptor.formatVersion)),
            ]
            for (key, value) in meta {
                try db.execute(sql: "INSERT INTO meta VALUES (?, ?)", arguments: [key, value])
            }
            if let salesChecked {
                try db.execute(sql: "CREATE TABLE productSales (productId INTEGER PRIMARY KEY)")
                try db.execute(sql: "INSERT INTO meta VALUES ('salesCheckedAt', ?)", arguments: [builtAt])
                for id in salesChecked {
                    try db.execute(sql: "INSERT INTO productSales VALUES (?)", arguments: [id])
                }
            }
            for card in cards {
                let parsed = CollectorNumber.parse(card.number)
                try db.execute(
                    sql: "INSERT INTO product VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?, NULL, 'Common', 'pokemon', 0, 1)",
                    arguments: [card.id, Fixture.chineseGemPack, TCGCategory.pokemonChinese, card.name, NameCleaner.clean(card.name), card.number, parsed.numberNum, parsed.setTotal]
                )
                try db.execute(sql: "INSERT INTO price VALUES (?, 'Holofoil', 149, NULL, NULL, NULL, NULL, '2026-09-13')", arguments: [card.id])
                try db.execute(sql: "INSERT INTO productLocalName VALUES (?, ?)", arguments: [card.id, card.local])
                let name = "\(card.name) \(card.local)"
                let setName = "Gem Pack Vol 4 宝石包4 CBB4C"
                try db.execute(sql: "INSERT INTO ftsText VALUES (?, ?, ?, ?)", arguments: [card.id, name, card.number, setName])
                try db.execute(sql: "INSERT INTO product_fts(rowid, name, number, setName) VALUES (?, ?, ?, ?)", arguments: [card.id, name, card.number, setName])
                try db.execute(sql: "INSERT INTO product_trigram(rowid, name, number) VALUES (?, ?, ?)", arguments: [card.id, name, card.number])
                try db.execute(
                    sql: "INSERT INTO productArt VALUES (?, ?)",
                    arguments: [card.id, CardArtDescriptor.data(from: Fixture.artDescriptor(seed: UInt64(card.id)))]
                )
            }
        }
        try queue.close()
        return url
    }

    private static func read<T>(_ catalog: URL, _ block: (Database) throws -> T) throws -> T {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: catalog.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read(block)
    }

    private static func search(_ text: String, in catalog: URL) throws -> Set<Int> {
        try read(catalog) { db in
            let request = SearchRequest(text: text, context: .browsing, filter: SearchFilter())
            return Set(try CatalogSearch.search(db, request: request).map(\.productId))
        }
    }

    /// Both search indexes are contentless, and a bad delete corrupts one
    /// without an error. This is the check that would see it.
    private static func checkIndexes(_ catalog: URL) throws {
        let queue = try DatabaseQueue(path: catalog.path)
        defer { try? queue.close() }
        try queue.write { db in
            try db.execute(sql: "INSERT INTO product_fts(product_fts) VALUES('integrity-check')")
            try db.execute(sql: "INSERT INTO product_trigram(product_trigram) VALUES('integrity-check')")
        }
    }

    @Test func aMergedCatalogFindsTheChineseCardByEitherName() throws {
        let dir = try Self.directory()
        let catalog = try Self.catalogFile(in: dir)
        let chinese = try Self.chineseFile(in: dir, named: "a.sqlite", builtAt: "2026-09-14T00:00:00Z", cards: [Self.ponyta, Self.surskit])
        try ChineseCatalog.apply(chinese, to: catalog)

        #expect(try Self.search("小火马", in: catalog) == [Fixture.chinesePonyta])
        #expect(try Self.search("Ponyta", in: catalog).contains(Fixture.chinesePonyta))
        #expect(try Self.search("Charizard", in: catalog).contains(1))
        let (merged, nearest) = try Self.read(catalog) { db in
            (
                try ChineseCatalog.mergedBuiltAt(db),
                try ArtIndex.load(db).nearest(
                    to: Fixture.artDescriptor(seed: UInt64(Fixture.chinesePonyta)), limit: 1,
                    scope: .only(TCGCategory.pokemonChinese)
                ).first?.productId
            )
        }
        #expect(merged == "2026-09-14T00:00:00Z")
        #expect(nearest == Fixture.chinesePonyta)
        try Self.checkIndexes(catalog)
    }

    @Test func aSecondImportReplacesTheFirst() throws {
        let dir = try Self.directory()
        let catalog = try Self.catalogFile(in: dir)
        try ChineseCatalog.apply(
            try Self.chineseFile(in: dir, named: "a.sqlite", builtAt: "2026-09-14T00:00:00Z", cards: [Self.ponyta, Self.surskit]),
            to: catalog
        )
        try ChineseCatalog.apply(
            try Self.chineseFile(in: dir, named: "b.sqlite", builtAt: "2026-09-15T00:00:00Z", cards: [Self.ponyta]),
            to: catalog
        )

        #expect(try Self.search("溜溜糖球", in: catalog).isEmpty)
        #expect(try Self.search("小火马", in: catalog) == [Fixture.chinesePonyta])
        #expect(try Self.search("Charmander", in: catalog).contains(3))
        let (count, merged) = try Self.read(catalog) { db in
            (
                try Int.fetchOne(db, sql: "SELECT count(*) FROM product WHERE categoryId = ?", arguments: [TCGCategory.pokemonChinese]),
                try ChineseCatalog.mergedBuiltAt(db)
            )
        }
        #expect(count == 1)
        #expect(merged == "2026-09-15T00:00:00Z")
        try Self.checkIndexes(catalog)
    }

    @Test func removingTheChineseCardsLeavesTheCatalogAsItWas() throws {
        let dir = try Self.directory()
        let catalog = try Self.catalogFile(in: dir)
        let before = try Self.search("char", in: catalog)
        try ChineseCatalog.apply(
            try Self.chineseFile(in: dir, named: "a.sqlite", builtAt: "2026-09-14T00:00:00Z", cards: [Self.ponyta]),
            to: catalog
        )
        try ChineseCatalog.apply(nil, to: catalog)

        #expect(try Self.search("char", in: catalog) == before)
        #expect(try Self.search("小火马", in: catalog).isEmpty)
        let (count, hasNames, merged) = try Self.read(catalog) { db in
            (
                try Int.fetchOne(db, sql: "SELECT count(*) FROM product"),
                try db.tableExists("productLocalName"),
                try ChineseCatalog.mergedBuiltAt(db)
            )
        }
        #expect(count == Fixture.products.count)
        #expect(!hasNames)
        #expect(merged == nil)
        try Self.checkIndexes(catalog)
    }

    /// A build that asked PikaQian lists the cards with eBay sales. Every other
    /// Chinese card has none, and the scan says "No sales".
    @Test func aChineseCardWithNoSalesIsKnown() throws {
        let dir = try Self.directory()
        let catalog = try Self.catalogFile(in: dir)
        let ids = [Fixture.chinesePonyta, Fixture.chineseSurskit, 1]
        try ChineseCatalog.apply(
            try Self.chineseFile(
                in: dir, named: "a.sqlite", builtAt: "2026-09-14T00:00:00Z",
                cards: [Self.ponyta, Self.surskit], salesChecked: [Fixture.chinesePonyta]
            ),
            to: catalog
        )
        #expect(try Self.read(catalog) { try ChineseCatalog.cardsWithNoSales($0, among: ids) } == [Fixture.chineseSurskit])

        // A build that did not ask claims nothing.
        try ChineseCatalog.apply(
            try Self.chineseFile(in: dir, named: "b.sqlite", builtAt: "2026-09-15T00:00:00Z", cards: [Self.ponyta, Self.surskit]),
            to: catalog
        )
        #expect(try Self.read(catalog) { try ChineseCatalog.cardsWithNoSales($0, among: ids) }.isEmpty)
        try Self.checkIndexes(catalog)
    }

    @Test func aFileThatIsNotAChineseCatalogIsRefused() throws {
        let dir = try Self.directory()
        let catalog = try Self.catalogFile(in: dir)
        #expect(throws: ChineseCatalog.Failure.notAChineseCatalog) {
            try ChineseCatalog.inspect(catalog)
        }
        let notes = dir.appendingPathComponent("notes.sqlite")
        try Data("not a database".utf8).write(to: notes)
        #expect(throws: (any Error).self) {
            try ChineseCatalog.inspect(notes)
        }
    }
}
