import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import BinderBooks

/// Finding the card in a frame, flattening it, and signing the artwork.
///
/// The scan reads text and nothing else today, so it cannot tell a card from
/// the card with the same number in another set, it cannot read a Japanese
/// name the catalog does not hold, and it cannot see the foil pattern that is
/// the whole difference between a 30 cent Snivy and an 18 dollar one. All three
/// are visible. These are the tests for looking.
@Suite struct CardArtTests {
    /// A card front: a coloured ground, a big shape, and a line of text. Two
    /// cards drawn with different hues and shapes are as different to a
    /// feature print as two real cards are.
    static func drawCard(hue: CGFloat, sides: Int, label: String) -> CGImage {
        let size = CardRectifier.outputSize
        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            UIColor(hue: hue, saturation: 0.7, brightness: 0.95, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            UIColor(hue: fmod(hue + 0.45, 1), saturation: 0.9, brightness: 0.6, alpha: 1).setFill()
            let centre = CGPoint(x: size.width / 2, y: size.height * 0.42)
            let radius = size.width * 0.33
            let path = UIBezierPath()
            for corner in 0..<sides {
                let angle = CGFloat(corner) / CGFloat(sides) * 2 * .pi - .pi / 2
                let point = CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
                corner == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            path.close()
            path.fill()

            label.draw(
                at: CGPoint(x: size.width * 0.1, y: size.height * 0.78),
                withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 44),
                    .foregroundColor: UIColor.black,
                ]
            )
        }.cgImage!
    }

    /// The card as the camera sees it: on a desk, turned, and not filling the
    /// frame. This is the input the scanner actually gets.
    static func photograph(_ card: CGImage, rotation: CGFloat) -> CGImage {
        let frame = CGSize(width: 1000, height: 1000)
        return UIGraphicsImageRenderer(size: frame).image { context in
            let cg = context.cgContext
            UIColor(white: 0.18, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: frame))

            let drawn = CGSize(width: 420, height: 588)
            cg.translateBy(x: frame.width / 2, y: frame.height / 2)
            cg.rotate(by: rotation)
            cg.translateBy(x: -drawn.width / 2, y: -drawn.height / 2)
            // UIKit's context is flipped against Core Graphics, so the image
            // goes in through UIImage to land the right way up.
            UIImage(cgImage: card).draw(in: CGRect(origin: .zero, size: drawn))
        }.cgImage!
    }

    private static let snivy = drawCard(hue: 0.30, sides: 3, label: "Snivy")
    private static let klink = drawCard(hue: 0.62, sides: 6, label: "Klink")

    // MARK: - Finding the card

    @Test func findsTheCardInTheFrame() throws {
        let photo = Self.photograph(Self.snivy, rotation: 0.12)
        let found = try CardRectifier.rectify(photo)
        #expect(found != nil)
        #expect(found!.confidence > 0.6)
        #expect(found!.image.width == Int(CardRectifier.outputSize.width))
        #expect(found!.image.height == Int(CardRectifier.outputSize.height))
    }

    /// An empty desk is not a card. Nil is the right answer, and the caller
    /// falls back to the text it already read.
    @Test func anEmptyFrameYieldsNoCard() throws {
        let empty = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 1000)).image { context in
            UIColor(white: 0.18, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1000, height: 1000))
        }.cgImage!
        #expect(try CardRectifier.rectify(empty) == nil)
    }

    // MARK: - The arithmetic

    /// A stand-in for one Vision print. The feature print needs the neural
    /// engine, which the simulator does not have, so the projection and the
    /// quantising are tested on vectors made here instead. That is the half
    /// that can go wrong quietly: it has to give the same answer in CI, on the
    /// build machine, and on the phone.
    static func rawPrint(seed: UInt64) -> [Float] {
        var rng = SplitMix64(state: seed)
        return (0..<CardArtDescriptor.sourceDimensions).map { _ in
            Float(rng.next() % 2000) / 1000 - 1
        }
    }

    /// The same card photographed twice: mostly the same vector, nudged.
    static func nudged(_ raw: [Float], by amount: Float, seed: UInt64) -> [Float] {
        var rng = SplitMix64(state: seed)
        return raw.map { $0 + (Float(rng.next() % 2000) / 1000 - 1) * amount }
    }

    @Test func theSignatureIsTheRightShape() {
        let signature = CardArtDescriptor.make(fromRaw: Self.rawPrint(seed: 1))
        #expect(signature?.count == CardArtDescriptor.dimensions)
        // A print of the wrong width is refused, not padded into nonsense.
        #expect(CardArtDescriptor.make(fromRaw: [1, 2, 3]) == nil)
    }

    @Test func aSignatureSurvivesTheTripThroughBytes() throws {
        let signature = try #require(CardArtDescriptor.make(fromRaw: Self.rawPrint(seed: 2)))
        let data = CardArtDescriptor.data(from: signature)
        #expect(data.count == CardArtDescriptor.dimensions)
        #expect(CardArtDescriptor.descriptor(from: data) == signature)
        // A row from an older catalog, or a truncated one, is refused rather
        // than compared as if it meant something.
        #expect(CardArtDescriptor.descriptor(from: data.dropLast()) == nil)
    }

    /// The signature is a pure function of the print. If this ever fails, the
    /// catalog and the phone have stopped agreeing and every distance is noise.
    @Test func theSameSignatureComesOutEveryTime() throws {
        let raw = Self.rawPrint(seed: 3)
        let a = try #require(CardArtDescriptor.make(fromRaw: raw))
        let b = try #require(CardArtDescriptor.make(fromRaw: raw))
        #expect(a == b)
        #expect(CardArtDescriptor.distance(a, b) == 0)
    }

    @Test func differentArtworkIsFarApart() throws {
        let a = try #require(CardArtDescriptor.make(fromRaw: Self.rawPrint(seed: 4)))
        let b = try #require(CardArtDescriptor.make(fromRaw: Self.rawPrint(seed: 5)))
        #expect(CardArtDescriptor.distance(a, b) > CardArtDescriptor.sameCard)
    }

    /// The projection has to keep the order it was given. Two photographs of
    /// one card must stay nearer to each other than either is to another card,
    /// after being squeezed from 768 floats into 128 bytes.
    @Test func theProjectionKeepsWhatIsNearNear() throws {
        let card = Self.rawPrint(seed: 6)
        let sameCardAgain = Self.nudged(card, by: 0.25, seed: 7)
        let otherCard = Self.rawPrint(seed: 8)

        let a = try #require(CardArtDescriptor.make(fromRaw: card))
        let b = try #require(CardArtDescriptor.make(fromRaw: sameCardAgain))
        let c = try #require(CardArtDescriptor.make(fromRaw: otherCard))

        #expect(CardArtDescriptor.distance(a, b) < CardArtDescriptor.distance(a, c))
        #expect(CardArtDescriptor.distance(a, b) < CardArtDescriptor.sameCard)
    }

    @Test func mismatchedSignaturesNeverCompareAsNear() {
        #expect(CardArtDescriptor.distance([], []) == .greatestFiniteMagnitude)
        #expect(CardArtDescriptor.distance([1, 2], [1, 2, 3]) == .greatestFiniteMagnitude)
    }

    // MARK: - The Vision leg

    /// The whole point, end to end. A photograph of a card, taken at an angle
    /// across a desk, must sign closer to that card's own reference art than to
    /// another card's. Without the rectifier this compares a desk against a
    /// card and the answer is noise.
    ///
    /// Runs on a device only. The simulator has no neural engine and answers
    /// "failed to create espresso context" to every feature print.
    @Test(.enabled(if: CardArtDescriptor.isAvailable))
    func aPhotographedCardMatchesItsOwnArtwork() throws {
        let photo = Self.photograph(Self.snivy, rotation: 0.12)
        let rectified = try #require(try CardRectifier.rectify(photo))
        let scanned = try #require(try CardArtDescriptor.make(from: rectified.image))
        let itsOwn = try #require(try CardArtDescriptor.make(from: Self.snivy))
        let another = try #require(try CardArtDescriptor.make(from: Self.klink))

        let toOwn = CardArtDescriptor.distance(scanned, itsOwn)
        let toOther = CardArtDescriptor.distance(scanned, another)
        #expect(toOwn < toOther)
        #expect(toOwn < CardArtDescriptor.sameCard)
    }
}
