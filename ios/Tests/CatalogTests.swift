import Foundation
import GRDB
import Testing
@testable import BinderBooks

// A gzip of 200 lines of "card tracker gunzip fixture line NNN". 7,400 bytes raw.
private let gzipFixtureBase64 = """
H4sIAAAAAAACE43Xy4lUUQAA0b1RvBC67n3fcIa2lUYZpJkBMXrNwLOvVe3O/e31dfl4vd1/PF7L98/3P89fy7fn74/P12P5+Xx/LLfb7cv9/1ESDYmmRKtEm0S7RIdEp0QXRMnx5HhyPDmeHE+OJ8eT48nx5PiQ40OODzk+5PiQ40OODzk+5PiQ40OOTzk+5fiU41OOTzk+5fiU41OOTzk+5fgqx1c5vsrxVY6vcnyV46scX+X4KsdXOb7J8U2Ob3J8k+ObHN/k+CbHNzm+yfFNju9yfJfjuxzf5fgux3c5vsvxXY7vcnyX44ccP+T4IccPOX7I8UOOH3L8kOOHHD/k+CnHTzl+yvFTjp9y/JTjpxw/5fgpx085fsnxS45fcvyS45ccv+T4JccvOX7J8QuOJ+ZMzJmYMzFnYs7EnIk5E3Mm5kzMmZgzMWdizsSciTkTcybmTMyZmDMxZ2LOxJyJORNzJuZMzJmYMzFnYs7EnIk5E3Mm5kzMmZgzMWdizsSciTkTcybmTMyZmDMxZ2LOxJyJORNzJuZMzJmYMzFnYs7EnIk5E3Mm5kzMmZgzMWdizsSciTkTcybmTMyZmDMxZ2LOxJyJORNzJuZMzJmYMzFnYs7EnIk5E3Mm5kzMmZgzMWdizsSciTkTcybmTMyZmDMxZ2LOxJyJORNzJuZMzJmYs3/m/Asi3kvM6BwAAA==
"""

private func scratchDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func sampleManifest(sha: String = "abc", productCount: Int = 3, schema: Int = 1) -> CatalogManifest {
    CatalogManifest(
        schemaVersion: schema,
        builtAt: "2026-09-10T04:24:05Z",
        sourceDate: "2026-09-10",
        sizeBytes: 12_074_642,
        sha256: sha,
        productCount: productCount,
        categories: [.init(categoryId: 3, name: "Pokemon", productCount: productCount)],
        url: URL(string: "https://example.invalid/catalog.sqlite.gz")!
    )
}

private func sampleMeta(productCount: Int = 3, schema: Int = 1) -> CatalogMeta {
    CatalogMeta(
        schemaVersion: schema,
        builtAt: "2026-09-10T04:24:05Z",
        sourceDate: "2026-09-10",
        productCount: productCount,
        categories: [.init(categoryId: 3, name: "Pokemon", productCount: productCount)]
    )
}

@Suite struct GunzipTests {
    @Test func decompressesAGzipFile() throws {
        let dir = try scratchDirectory()
        let gz = dir.appendingPathComponent("fixture.gz")
        let out = dir.appendingPathComponent("fixture.txt")
        try Data(base64Encoded: gzipFixtureBase64, options: .ignoreUnknownCharacters)!.write(to: gz)

        try Gunzip.decompress(from: gz, to: out)

        let text = try String(contentsOf: out, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 200)
        #expect(lines.first == "card tracker gunzip fixture line 000")
        #expect(lines.last == "card tracker gunzip fixture line 199")
    }

    @Test func rejectsATruncatedFile() throws {
        let dir = try scratchDirectory()
        let gz = dir.appendingPathComponent("truncated.gz")
        let out = dir.appendingPathComponent("out.txt")
        let whole = Data(base64Encoded: gzipFixtureBase64, options: .ignoreUnknownCharacters)!
        try whole.prefix(whole.count / 2).write(to: gz)

        #expect(throws: CatalogError.self) {
            try Gunzip.decompress(from: gz, to: out)
        }
    }

    @Test func rejectsAFileThatIsNotGzip() throws {
        let dir = try scratchDirectory()
        let notGz = dir.appendingPathComponent("plain.txt")
        try Data("this is not gzip".utf8).write(to: notGz)

        #expect(throws: CatalogError.self) {
            try Gunzip.decompress(from: notGz, to: dir.appendingPathComponent("out"))
        }
    }
}

@Suite struct ChecksumTests {
    @Test func sha256MatchesAKnownValue() throws {
        let dir = try scratchDirectory()
        let file = dir.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)
        #expect(try Checksum.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@Suite struct ManifestTests {
    @Test func decodesTheJobsManifest() throws {
        let json = """
        {
          "schemaVersion": 1,
          "builtAt": "2026-09-10T04:24:05Z",
          "sourceDate": "2026-09-10",
          "sizeBytes": 12074642,
          "sha256": "fcfc61aa913682d9438675103a8d4fc80fc9506e9b20b6db687407ad076e246f",
          "productCount": 79802,
          "categories": [
            {"categoryId": 3, "name": "Pokemon", "productCount": 32676},
            {"categoryId": 85, "name": "Pokemon Japan", "productCount": 30453}
          ],
          "url": "https://github.com/ajhollowayvrm/binderbooks/releases/download/catalog-latest/catalog.sqlite.gz"
        }
        """
        let manifest = try JSONDecoder().decode(CatalogManifest.self, from: Data(json.utf8))
        #expect(manifest.productCount == 79802)
        #expect(manifest.categories.count == 2)
        #expect(manifest.categories[1].name == "Pokemon Japan")
        #expect(manifest.builtAtDate != nil)
        #expect(manifest.url.lastPathComponent == "catalog.sqlite.gz")
    }

    @Test func roundTripsThroughTheEncoder() throws {
        let original = sampleManifest()
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(CatalogManifest.self, from: data) == original)
    }
}

@Suite struct SanityTests {
    @Test func acceptsAMatchingFile() throws {
        try CatalogSanity.checkFile(meta: sampleMeta(), manifest: sampleManifest(), previousProductCount: nil)
        try CatalogSanity.checkFile(meta: sampleMeta(productCount: 80_000), manifest: sampleManifest(productCount: 80_000), previousProductCount: 79_802)
    }

    @Test func refusesANewerSchemaInTheManifest() {
        #expect(throws: CatalogError.schemaTooNew(manifest: 2, supported: 1)) {
            try CatalogSanity.checkManifest(sampleManifest(schema: 2))
        }
    }

    @Test func refusesAFileWithTheWrongSchema() {
        #expect(throws: CatalogError.schemaMismatch(file: 2, supported: 1)) {
            try CatalogSanity.checkFile(meta: sampleMeta(schema: 2), manifest: sampleManifest(), previousProductCount: nil)
        }
    }

    @Test func refusesAProductCountThatDisagreesWithTheManifest() {
        #expect(throws: CatalogError.productCountMismatch(manifest: 3, file: 2)) {
            try CatalogSanity.checkFile(meta: sampleMeta(productCount: 2), manifest: sampleManifest(productCount: 3), previousProductCount: nil)
        }
    }

    @Test func refusesALargeDropAgainstTheInstalledCatalog() {
        #expect(throws: CatalogError.productCountDropped(previous: 80_000, new: 30_000)) {
            try CatalogSanity.checkFile(meta: sampleMeta(productCount: 30_000), manifest: sampleManifest(productCount: 30_000), previousProductCount: 80_000)
        }
    }

    @Test func allowsAModestDrop() throws {
        try CatalogSanity.checkFile(meta: sampleMeta(productCount: 70_000), manifest: sampleManifest(productCount: 70_000), previousProductCount: 80_000)
    }

    @Test func newerMeansADifferentChecksum() {
        #expect(CatalogSanity.isNewer(sampleManifest(sha: "a"), than: nil))
        #expect(CatalogSanity.isNewer(sampleManifest(sha: "a"), than: sampleManifest(sha: "b")))
        #expect(!CatalogSanity.isNewer(sampleManifest(sha: "a"), than: sampleManifest(sha: "a")))
    }
}

@Suite struct CatalogDatabaseTests {
    @Test func readsTheMetaTable() throws {
        let dir = try scratchDirectory()
        let path = dir.appendingPathComponent("catalog.sqlite").path
        let writer = try DatabaseQueue(path: path)
        try writer.write { db in
            try db.execute(sql: "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO meta VALUES ('schemaVersion', '1')")
            try db.execute(sql: "INSERT INTO meta VALUES ('builtAt', '2026-09-10T04:24:05Z')")
            try db.execute(sql: "INSERT INTO meta VALUES ('sourceDate', '2026-09-10')")
            try db.execute(sql: "INSERT INTO meta VALUES ('productCount', '79802')")
            try db.execute(sql: "INSERT INTO meta VALUES ('categories', '[{\"categoryId\":3,\"name\":\"Pokemon\",\"productCount\":79802}]')")
        }
        try writer.close()

        let catalog = try CatalogDatabase(path: path)
        let meta = try catalog.meta()
        #expect(meta.schemaVersion == 1)
        #expect(meta.productCount == 79802)
        #expect(meta.categories.first?.name == "Pokemon")
        try catalog.close()
    }

    @Test func anIncompleteMetaTableIsAnError() throws {
        let dir = try scratchDirectory()
        let path = dir.appendingPathComponent("catalog.sqlite").path
        let writer = try DatabaseQueue(path: path)
        try writer.write { db in
            try db.execute(sql: "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO meta VALUES ('schemaVersion', '1')")
        }
        try writer.close()

        let catalog = try CatalogDatabase(path: path)
        #expect(throws: CatalogError.metaIncomplete(["schemaVersion"])) {
            try catalog.meta()
        }
    }

    @Test func fts5IsAvailableInTheSystemSQLite() throws {
        let dir = try scratchDirectory()
        let writer = try DatabaseQueue(path: dir.appendingPathComponent("fts.sqlite").path)
        try writer.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE t USING fts5(name, tokenize='unicode61 remove_diacritics 2', prefix='2 3 4')")
            try db.execute(sql: "CREATE VIRTUAL TABLE tri USING fts5(name, tokenize='trigram')")
            try db.execute(sql: "INSERT INTO t(rowid, name) VALUES (1, 'Charizard ex')")
            try db.execute(sql: "INSERT INTO tri(rowid, name) VALUES (1, 'Charizard ex')")
        }
        let prefix = try writer.read { db in try Int.fetchAll(db, sql: "SELECT rowid FROM t WHERE t MATCH 'char*'") }
        let trigram = try writer.read { db in try Int.fetchAll(db, sql: "SELECT rowid FROM tri WHERE tri MATCH '\"cha\" OR \"arz\"'") }
        #expect(prefix == [1])
        #expect(trigram == [1])
    }
}
