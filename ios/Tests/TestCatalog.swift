import Foundation
import GRDB
@testable import BinderBooks

// MARK: - Fixture

/// A tiny catalog with the real schema from catalog/build_catalog.py.
enum Fixture {
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
        // The Cyndaquil case. Combusken owns 004/131; the Cyndaquil he is
        // holding is 004/162 in another set, so a misread total lands on
        // Combusken and nothing else.
        Product(id: 10, groupId: 105, categoryId: 3, name: "Combusken", number: "004/131", rarity: "Common", sealed: false, prices: [("Normal", 25)]),
        Product(id: 11, groupId: 106, categoryId: 3, name: "Cyndaquil", number: "004/162", rarity: "Common", sealed: false, prices: [("Normal", 40)]),
        // A decoy for the trigram fallback: shares the "pro" trigram with
        // "promo" but nothing else. A query for a promo card by name must not
        // pull this in just because path A came back thin.
        Product(id: 12, groupId: 106, categoryId: 3, name: "Professional Grade Toploader", number: nil, rarity: nil, sealed: true, prices: [("Normal", 199)]),
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
                (105, 3, 'SV04: Paradox Rift', 'PAR', '2023-11-03T00:00:00'),
                (106, 3, 'SV08: Surging Sparks', 'SSP', '2024-11-08T00:00:00'),
                (100, 3, 'SV03: Obsidian Flames', 'OBF', '2023-08-11T00:00:00'),
                (101, 3, 'Base Set', 'BS', '1999-01-09T00:00:00'),
                (102, 3, 'SWSH: Sword & Shield Promo Cards', 'PR-SW', '2020-02-07T00:00:00'),
                (103, 85, 'M6: Storm Emeralda', 'M6', '2026-08-01T00:00:00'),
                (104, 63, 'Timeless Bonds', 'BT-26', '2026-07-01T00:00:00');
            """)
            let setNames = [
            100: "SV03: Obsidian Flames", 101: "Base Set", 102: "SWSH: Sword & Shield Promo Cards",
            103: "M6: Storm Emeralda", 104: "Timeless Bonds", 105: "SV04: Paradox Rift", 106: "SV08: Surging Sparks",
        ]
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

