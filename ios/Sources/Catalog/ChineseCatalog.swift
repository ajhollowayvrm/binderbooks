import Foundation
import GRDB

/// The Simplified Chinese cards: a second catalog file, built on the Mac from
/// PikaQian and imported through Files.
///
/// TCGplayer carries no Chinese cards, so the published catalog cannot hold
/// them. He builds `chinese-catalog.sqlite` with
/// scripts/build-chinese-catalog.sh, and the app adds its rows to the live
/// catalog: one search, one artwork index, one set of queries. The file never
/// goes to GitHub.
///
/// The live catalog is replaced, never edited in place. A merge runs on a
/// copy, and the copy swaps in the way a download does. A new download arrives
/// without the Chinese rows, so every swap merges them again.
enum ChineseCatalog {
    static let kind = "pokemon-zh-hans"
    static let formatVersion = 1
    /// The meta key a merged catalog carries: the `builtAt` of the Chinese
    /// file in it.
    static let mergedKey = "chineseBuiltAt"

    struct Info: Equatable, Sendable {
        var builtAt: String
        var pricedAt: String?
        var productCount: Int
    }

    enum Failure: LocalizedError, Equatable {
        case notAChineseCatalog
        case formatTooNew(Int)
        case schemaMismatch(Int)
        case artworkMismatch
        case noCatalog

        var errorDescription: String? {
            switch self {
            case .notAChineseCatalog:
                return "This file is not a Chinese catalog from scripts/build-chinese-catalog.sh."
            case .formatTooNew(let version):
                return "The Chinese catalog is format \(version). This build reads format \(ChineseCatalog.formatVersion). Update the app."
            case .schemaMismatch(let version):
                return "The Chinese catalog uses schema \(version). This build reads schema \(supportedCatalogSchemaVersion). Build it again on the Mac."
            case .artworkMismatch:
                return "Another version of the artwork signer signed the Chinese catalog. Build it again on the Mac."
            case .noCatalog:
                return "Install the catalog first."
            }
        }
    }

    /// Check a file before it goes near the live catalog.
    static func inspect(_ url: URL) throws -> Info {
        var configuration = Configuration()
        configuration.readonly = true
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path, configuration: configuration)
        } catch {
            throw Failure.notAChineseCatalog
        }
        defer { try? queue.close() }
        return try queue.read { db in try info(db) }
    }

    static func info(_ db: Database) throws -> Info {
        guard try db.tableExists("meta"), try db.tableExists("ftsText") else { throw Failure.notAChineseCatalog }
        var rows: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT key, value FROM meta") {
            rows[row["key"]] = row["value"]
        }
        guard rows["kind"] == kind,
              let format = rows["formatVersion"].flatMap(Int.init),
              let schema = rows["schemaVersion"].flatMap(Int.init),
              let builtAt = rows["builtAt"],
              let count = rows["productCount"].flatMap(Int.init)
        else { throw Failure.notAChineseCatalog }
        guard format <= formatVersion else { throw Failure.formatTooNew(format) }
        guard schema == supportedCatalogSchemaVersion else { throw Failure.schemaMismatch(schema) }
        let signed = try db.tableExists("productArt")
            ? try Int.fetchOne(db, sql: "SELECT count(*) FROM productArt") ?? 0
            : 0
        if signed > 0, rows["artFormatVersion"] != String(CardArtDescriptor.formatVersion) {
            throw Failure.artworkMismatch
        }
        return Info(builtAt: builtAt, pricedAt: rows["pricedAt"], productCount: count)
    }

    /// The `builtAt` of the Chinese file merged into a catalog, or nil.
    static func mergedBuiltAt(_ db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [mergedKey])
    }

    /// Replace the Chinese rows of a catalog file with the rows of `chinese`,
    /// in one transaction. Nil takes them out and puts nothing in.
    ///
    /// The rows come out by category, so this needs no record of what went in
    /// before, and running it twice changes nothing. `meta.productCount` is
    /// left alone: the download checks compare it with the published catalog,
    /// which holds no Chinese cards.
    static func apply(_ chinese: URL?, to catalog: URL) throws {
        let incoming = try chinese.map(inspect)
        let queue = try DatabaseQueue(path: catalog.path)
        defer { try? queue.close() }
        try queue.writeWithoutTransaction { db in
            if let chinese {
                try db.execute(sql: "ATTACH DATABASE ? AS zh", arguments: [chinese.path])
            }
            defer {
                if chinese != nil { try? db.execute(sql: "DETACH DATABASE zh") }
            }
            try db.inTransaction {
                let present = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS (SELECT 1 FROM main.product WHERE categoryId = ?)",
                    arguments: [TCGCategory.pokemonChinese]
                ) ?? false
                if present {
                    try db.execute(sql: removeSQL, arguments: [
                        TCGCategory.pokemonChinese, TCGCategory.pokemonChinese, TCGCategory.pokemonChinese,
                        TCGCategory.pokemonChinese, TCGCategory.pokemonChinese,
                    ])
                }
                if let incoming {
                    try db.execute(sql: insertSQL)
                    try db.execute(
                        sql: "INSERT INTO main.meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                        arguments: [mergedKey, incoming.builtAt]
                    )
                } else {
                    try db.execute(sql: "DELETE FROM main.meta WHERE key = ?", arguments: [mergedKey])
                }
                return .commit
            }
        }
    }

    /// Take the Chinese rows out, and rebuild both search indexes from what is
    /// left.
    ///
    /// Both indexes are contentless: a row comes out only when the delete
    /// repeats every word that went in, and a delete that repeats the wrong
    /// words corrupts the index without an error. Rebuilding is the safe road,
    /// and the words are all in the catalog: this mirrors `build_sqlite` in
    /// catalog/build_catalog.py, which indexes the product name, the number,
    /// and the set name. Keep the two in step.
    private static let removeSQL = """
    DELETE FROM main.price WHERE productId IN (SELECT productId FROM main.product WHERE categoryId = ?);
    DELETE FROM main.productArt WHERE productId IN (SELECT productId FROM main.product WHERE categoryId = ?);
    DROP TABLE IF EXISTS main.productLocalName;
    DELETE FROM main.product WHERE categoryId = ?;
    DELETE FROM main.cardSet WHERE categoryId = ?;
    DELETE FROM main.category WHERE categoryId = ?;
    INSERT INTO main.product_fts(product_fts) VALUES('delete-all');
    INSERT INTO main.product_trigram(product_trigram) VALUES('delete-all');
    INSERT INTO main.product_fts(rowid, name, number, setName)
        SELECT p.productId, p.name, coalesce(p.number, ''), s.name
        FROM main.product p JOIN main.cardSet s ON s.groupId = p.groupId;
    INSERT INTO main.product_trigram(rowid, name, number)
        SELECT productId, name, coalesce(number, '') FROM main.product;
    """

    /// The Chinese rows in. The index text comes from the file's `ftsText`,
    /// because it carries the Chinese names the catalog's own columns do not.
    private static let insertSQL = """
    CREATE TABLE IF NOT EXISTS main.productArt (productId INTEGER PRIMARY KEY, descriptor BLOB NOT NULL);
    CREATE TABLE IF NOT EXISTS main.productLocalName (productId INTEGER PRIMARY KEY, localName TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS main.idx_local_name ON productLocalName(localName);
    INSERT INTO main.category (categoryId, name, displayName)
        SELECT categoryId, name, displayName FROM zh.category;
    INSERT INTO main.cardSet (groupId, categoryId, name, abbreviation, publishedOn)
        SELECT groupId, categoryId, name, abbreviation, publishedOn FROM zh.cardSet;
    INSERT INTO main.product (productId, groupId, categoryId, name, cleanName, imageUrl, number, numberNum,
                              setTotal, setCode, rarity, cardType, isSealed, printingCount)
        SELECT productId, groupId, categoryId, name, cleanName, imageUrl, number, numberNum,
               setTotal, setCode, rarity, cardType, isSealed, printingCount FROM zh.product;
    INSERT INTO main.price (productId, subTypeName, marketPriceCents, lowPriceCents, midPriceCents,
                            highPriceCents, directLowPriceCents, asOf)
        SELECT productId, subTypeName, marketPriceCents, lowPriceCents, midPriceCents,
               highPriceCents, directLowPriceCents, asOf FROM zh.price;
    INSERT INTO main.productArt (productId, descriptor) SELECT productId, descriptor FROM zh.productArt;
    INSERT INTO main.productLocalName (productId, localName) SELECT productId, localName FROM zh.productLocalName;
    INSERT INTO main.product_fts(rowid, name, number, setName) SELECT productId, name, number, setName FROM zh.ftsText;
    INSERT INTO main.product_trigram(rowid, name, number) SELECT productId, name, number FROM zh.ftsText;
    """
}
