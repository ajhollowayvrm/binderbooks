import Foundation
import GRDB
import Testing
@testable import BinderBooks

/// The whole-catalog artwork search, on signatures we write ourselves.
///
/// No Vision and no catalog file. Vision cannot sign anything in the simulator
/// — feature prints need the neural engine — so these tests build signatures
/// directly and check the search over them. What Vision makes of a real card
/// is `CardArtTests`' job, on a device.
@Suite struct ArtIndexTests {
    /// A signature that points in a direction of its own, so two made with
    /// different seeds sit far apart and one made twice sits at zero.
    static func signature(seed: UInt64) -> [Int8] {
        var rng = SplitMix64(state: seed)
        return (0..<CardArtDescriptor.dimensions).map { _ in
            Int8(truncatingIfNeeded: Int(rng.next() % 255) - 127)
        }
    }

    static func index(_ entries: [(Int, [Int8])]) -> ArtIndex {
        var ids: [Int32] = []
        var values: [Int8] = []
        var norms: [Float] = []
        for (id, descriptor) in entries {
            ids.append(Int32(id))
            values.append(contentsOf: descriptor)
            norms.append(descriptor.reduce(Float(0)) { $0 + Float($1) * Float($1) }.squareRoot())
        }
        return ArtIndex(productIds: ids, values: values, norms: norms)
    }

    @Test func aSignatureFindsItselfFirstAndAtZero() {
        let wanted = Self.signature(seed: 7)
        let art = Self.index([(1, Self.signature(seed: 1)), (2, wanted), (3, Self.signature(seed: 3))])
        let found = art.nearest(to: wanted, limit: 3)
        #expect(found.first?.productId == 2)
        #expect((found.first?.distance ?? 1) < 0.0001)
    }

    @Test func theAnswerIsSortedNearestFirstAndCappedAtTheLimit() {
        let art = Self.index((1...20).map { ($0, Self.signature(seed: UInt64($0))) })
        let found = art.nearest(to: Self.signature(seed: 5), limit: 4)
        #expect(found.count == 4)
        #expect(found == found.sorted { $0.distance < $1.distance })
        #expect(found.first?.productId == 5)
    }

    /// The index and the pairwise comparison must agree to the last decimal.
    /// The thresholds the matcher is written in are numbers on one scale, and
    /// two pieces of arithmetic that drift make every one of them a lie.
    @Test func theIndexMeasuresTheSameDistanceThePairwiseTestDoes() {
        let a = Self.signature(seed: 11)
        let b = Self.signature(seed: 12)
        let art = Self.index([(1, b)])
        let found = try? #require(art.nearest(to: a, limit: 1).first)
        #expect(abs((found?.distance ?? 0) - CardArtDescriptor.distance(a, b)) < 0.0005)
    }

    @Test func anEmptyIndexAndAMalformedSignatureAnswerNothing() {
        #expect(Self.index([]).nearest(to: Self.signature(seed: 1)).isEmpty)
        let art = Self.index([(1, Self.signature(seed: 1))])
        #expect(art.nearest(to: [1, 2, 3]).isEmpty)
        #expect(art.nearest(to: Self.signature(seed: 1), limit: 0).isEmpty)
    }

    /// A signature of all zeros has no direction, so it cannot be compared
    /// with anything. It must be left out of the index rather than handed a
    /// distance the arithmetic cannot produce.
    @Test func aSignatureWithNoDirectionIsLeftOut() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE productArt (productId INTEGER PRIMARY KEY, descriptor BLOB NOT NULL);")
            try db.execute(sql: "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
            try db.execute(
                sql: "INSERT INTO meta VALUES ('artFormatVersion', ?)",
                arguments: [String(CardArtDescriptor.formatVersion)]
            )
            try db.execute(
                sql: "INSERT INTO productArt VALUES (?, ?)",
                arguments: [1, CardArtDescriptor.data(from: Self.signature(seed: 4))]
            )
            try db.execute(
                sql: "INSERT INTO productArt VALUES (?, ?)",
                arguments: [2, CardArtDescriptor.data(from: [Int8](repeating: 0, count: CardArtDescriptor.dimensions))]
            )
        }
        let art = try queue.read { db in try ArtIndex.load(db) }
        #expect(art.count == 1)
        #expect(art.nearest(to: Self.signature(seed: 4)).first?.productId == 1)
    }

    /// A catalog signed by arithmetic this build cannot reproduce carries
    /// signatures that mean something else. The index must come back empty and
    /// the matcher must fall back to words, rather than compare two unlike
    /// things and report a distance that is noise.
    @Test func aCatalogSignedByAnotherVersionBuildsNoIndex() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE productArt (productId INTEGER PRIMARY KEY, descriptor BLOB NOT NULL);")
            try db.execute(sql: "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
            try db.execute(
                sql: "INSERT INTO meta VALUES ('artFormatVersion', ?)",
                arguments: [String(CardArtDescriptor.formatVersion + 1)]
            )
            try db.execute(
                sql: "INSERT INTO productArt VALUES (?, ?)",
                arguments: [1, CardArtDescriptor.data(from: Self.signature(seed: 4))]
            )
        }
        let art = try queue.read { db in try ArtIndex.load(db) }
        #expect(art.isEmpty)
    }
}
