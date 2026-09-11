import CoreGraphics
import Foundation
import Vision

/// The artwork signature of one card, and the rules for comparing two of them.
///
/// Text alone cannot finish the job. Two cards can carry the same number in
/// different sets, a Japanese card's name is never the name the catalog holds,
/// and the pattern printings of one card share a name and a number and differ
/// only in the foil stamped across them. All three are visible, and none of
/// them is readable.
///
/// The signature is Vision's image feature print, cut down to something a
/// catalog can carry. The full print is 768 floats, which is 3 KB a card and
/// 58 MB over the catalog. A sign projection to 128 dimensions and one byte per
/// dimension brings that to 9.3 MB, and measurement on real cards says the
/// order survives: the pattern printings of a card stay nearer to it than any
/// other card does.
///
/// **The app and the catalog build tool both compile this file.** The signature
/// in the catalog and the signature from the camera must come out of the same
/// arithmetic, or every distance is noise. Nothing here may depend on UIKit.
enum CardArtDescriptor {
    /// Stored dimensions, and so the byte count of one signature.
    static let dimensions = 128

    /// Vision's print, before the projection.
    static let sourceDimensions = 768

    /// Bumped whenever the arithmetic below changes. The catalog records the
    /// version it was built with, and the app ignores a signature it cannot
    /// reproduce rather than comparing two different things.
    static let formatVersion = 1

    /// Pinned. Vision's revisions are not interchangeable, and an unpinned
    /// request would quietly change the meaning of every stored signature the
    /// day the OS updates.
    static let visionRevision = VNGenerateImageFeaturePrintRequestRevision2

    // MARK: - Making one

    /// The signature of an image, or nil when Vision cannot read it.
    ///
    /// Give this a rectified card and nothing else. A signature taken from the
    /// whole camera frame describes his desk as much as the card.
    static func make(from image: CGImage) throws -> [Int8]? {
        guard let raw = try featurePrint(of: image) else { return nil }
        return make(fromRaw: raw)
    }

    /// Vision's raw print, 768 floats. Nil when Vision declines the image.
    ///
    /// Separate from the arithmetic below on purpose. Feature prints need the
    /// neural engine, which the iOS simulator does not have — it answers
    /// "failed to create espresso context" — so the arithmetic has to be
    /// testable without ever calling this.
    static func featurePrint(of image: CGImage) throws -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = visionRevision
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let print = request.results?.first as? VNFeaturePrintObservation,
              print.elementCount == sourceDimensions,
              print.elementType == .float
        else { return nil }
        return print.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// True when this machine can sign artwork at all. False in the simulator.
    static var isAvailable: Bool {
        let pixels = CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let image = pixels?.makeImage() else { return false }
        return ((try? featurePrint(of: image)) ?? nil) != nil
    }

    /// The stored signature for a raw print. The whole of the arithmetic.
    static func make(fromRaw raw: [Float]) -> [Int8]? {
        guard raw.count == sourceDimensions else { return nil }
        return quantise(project(raw))
    }

    // MARK: - Comparing two

    /// Euclidean distance between two normalised signatures, 0 to 2.
    ///
    /// The scale is the one the thresholds below are written in, and it is the
    /// same scale Vision's own `computeDistance` reports, so a number measured
    /// on full prints still means what it meant.
    static func distance(_ a: [Int8], _ b: [Int8]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            let x = Float(a[i])
            let y = Float(b[i])
            dot += x * y
            normA += x * x
            normB += y * y
        }
        guard normA > 0, normB > 0 else { return .greatestFiniteMagnitude }
        let cosine = dot / (normA.squareRoot() * normB.squareRoot())
        return (2 - 2 * max(-1, min(1, cosine))).squareRoot()
    }

    /// Nearer than this and the artwork is the same card's artwork.
    ///
    /// Measured on the reference thumbnails: the pattern printings of one card
    /// sit at 0.53 to 0.73 from the plain card, and the nearest unrelated card
    /// sits at 0.84. The bar is set below that floor, because a wrong card that
    /// looks confident is worse than a card marked unknown.
    static let sameCard: Float = 0.78

    /// A camera frame is never as clean as the reference thumbnail it is
    /// compared against, so the bar for merely *ranking* candidates is looser
    /// than the bar for asserting a match on artwork alone.
    static let plausible: Float = 0.95

    // MARK: - The projection

    /// A sign projection, 768 down to 128. Generated from a fixed seed rather
    /// than shipped: a 393 KB matrix in the catalog is 393 KB that can go
    /// stale, and a seeded generator cannot disagree with itself.
    private static let matrix: [Float] = {
        var rng = SplitMix64(state: 0x8AC7_2304_89E8_0000)
        var values = [Float](repeating: 0, count: sourceDimensions * dimensions)
        let scale = 1 / Float(dimensions).squareRoot()
        for i in values.indices {
            values[i] = (rng.next() & 1) == 0 ? scale : -scale
        }
        return values
    }()

    private static func project(_ vector: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: dimensions)
        matrix.withUnsafeBufferPointer { m in
            for j in 0..<dimensions {
                var sum: Float = 0
                for i in 0..<sourceDimensions {
                    sum += vector[i] * m[i * dimensions + j]
                }
                out[j] = sum
            }
        }
        return out
    }

    /// Normalise to unit length, then one byte a dimension. Normalising first
    /// is what lets a fixed scale hold: without it a dark card and a bright one
    /// quantise at different resolutions.
    private static func quantise(_ vector: [Float]) -> [Int8] {
        var norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        if norm == 0 { norm = 1 }
        return vector.map { value in
            Int8(max(-127, min(127, (value / norm * 127).rounded())))
        }
    }

    // MARK: - Bytes

    static func data(from descriptor: [Int8]) -> Data {
        descriptor.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func descriptor(from data: Data) -> [Int8]? {
        guard data.count == dimensions else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Int8.self)) }
    }
}

/// A small, exactly specified generator. `SystemRandomNumberGenerator` is not
/// reproducible and `arc4random` is not either, and this number has to come out
/// the same on a build machine in CI and on the phone.
struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
