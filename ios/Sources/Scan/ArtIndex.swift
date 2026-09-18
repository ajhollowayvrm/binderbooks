import Foundation
import GRDB

/// Every signed card in the catalog, held in one buffer and searched by
/// artwork alone.
///
/// The scanner used to ask the catalog a question in words: "what card is
/// called this, and carries this number?" When the words were wrong the answer
/// was wrong, and the words are wrong often — an attack name is set in the same
/// type as a card name, a sleeve throws a highlight over the collector number,
/// and a Japanese card is filed under an English name it does not print. The
/// picture has none of those problems. It is the same picture TCGplayer scanned
/// and we already downloaded, and this index is the whole downloaded set,
/// 71,802 of them, ready to be asked "which of you is this?"
///
/// The answer is not a decision on its own. Measured against degraded
/// references over the whole index, the nearest card is the right card about
/// three times in five, the right card is in the nearest ten about nine times
/// in ten, and most of the near misses are the same card reprinted in another
/// set — right artwork, wrong row. So the index proposes and the text decides,
/// which is the reverse of what the scanner did before, and the right way
/// round: a shortlist of ten pictures that all look like the card in his hand
/// is a far better place for a collector number to do its work than the whole
/// catalog is.
struct ArtIndex: Sendable {
    /// One entry of an answer: a product, and how far its artwork sits from
    /// the artwork asked about. The scale is `CardArtDescriptor.distance`.
    struct Neighbour: Equatable, Sendable {
        var productId: Int
        var distance: Float
    }

    /// How many neighbours the matcher asks for.
    ///
    /// Ten holds the right card nine times in ten and thirty holds it 94 times
    /// in a hundred, so the extra twenty buy four points. They cost nothing to
    /// compute — the distances are all measured either way — and they cost one
    /// catalog row each to turn into a candidate. Worth it: the four points are
    /// the cards whose artwork the camera saw poorly, which are exactly the
    /// cards whose text needs the help.
    static let defaultLimit = 30

    private let productIds: [Int32]
    /// Every signature laid end to end, `CardArtDescriptor.dimensions` bytes
    /// each. One allocation, not 71,802, because the search reads all of it.
    private let values: [Int8]
    /// Each signature's length, computed once at load. The search needs it for
    /// every row and it never changes.
    private let norms: [Float]

    var count: Int { productIds.count }
    var isEmpty: Bool { productIds.isEmpty }

    init(productIds: [Int32], values: [Int8], norms: [Float]) {
        self.productIds = productIds
        self.values = values
        self.norms = norms
    }

    /// Build from the signatures in a catalog. Empty when the catalog carries
    /// none, which a catalog built before the signatures existed does not.
    static func load(_ db: Database) throws -> ArtIndex {
        guard try CatalogSearch.hasArtwork(db) else {
            return ArtIndex(productIds: [], values: [], norms: [])
        }
        let dimensions = CardArtDescriptor.dimensions
        var productIds: [Int32] = []
        var values: [Int8] = []
        var norms: [Float] = []

        let cursor = try Row.fetchCursor(db, sql: "SELECT productId, descriptor FROM productArt")
        while let row = try cursor.next() {
            let data: Data = row["descriptor"]
            guard data.count == dimensions else { continue }
            var norm: Float = 0
            data.withUnsafeBytes { bytes in
                let signature = bytes.bindMemory(to: Int8.self)
                for value in signature { norm += Float(value) * Float(value) }
                values.append(contentsOf: signature)
            }
            guard norm > 0 else {
                values.removeLast(dimensions)
                continue
            }
            productIds.append(row["productId"])
            norms.append(norm.squareRoot())
        }
        return ArtIndex(productIds: productIds, values: values, norms: norms)
    }

    /// The cards whose artwork is nearest to this signature, nearest first.
    ///
    /// Brute force over every row. An approximate index would be faster and is
    /// not worth its own correctness risk: 71,802 rows of 128 bytes is nine
    /// megabytes and a few milliseconds, and this runs once per card logged,
    /// not once per camera frame.
    func nearest(to descriptor: [Int8], limit: Int = defaultLimit) -> [Neighbour] {
        let dimensions = CardArtDescriptor.dimensions
        guard descriptor.count == dimensions, limit > 0, !productIds.isEmpty else { return [] }

        var queryNorm: Float = 0
        for value in descriptor { queryNorm += Float(value) * Float(value) }
        queryNorm = queryNorm.squareRoot()
        guard queryNorm > 0 else { return [] }

        var found: [Neighbour] = []
        found.reserveCapacity(productIds.count)
        descriptor.withUnsafeBufferPointer { query in
            values.withUnsafeBufferPointer { stored in
                for row in productIds.indices {
                    var dot: Int32 = 0
                    let base = row * dimensions
                    for i in 0..<dimensions {
                        dot &+= Int32(query[i]) * Int32(stored[base + i])
                    }
                    // The same arithmetic as `CardArtDescriptor.distance`, and
                    // it has to stay the same: the thresholds the matcher is
                    // written in are numbers on that scale.
                    let cosine = Float(dot) / (queryNorm * norms[row])
                    let clamped = max(-1, min(1, cosine))
                    found.append(Neighbour(
                        productId: Int(productIds[row]),
                        distance: (2 - 2 * clamped).squareRoot()
                    ))
                }
            }
        }
        found.sort { $0.distance < $1.distance }
        return Array(found.prefix(limit))
    }
}
