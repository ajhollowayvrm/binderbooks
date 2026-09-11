import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import BinderBooks

/// The scanner now owns the camera, which buys three things the old one could
/// not have: a focus score, a budget for what each frame is worth, and the
/// right to sign the sharpest look at a card rather than the latest one.
@Suite struct FrameSharpnessTests {
    /// Sharp edges: a checkerboard. Blurring it must cost it.
    static func checkerboard(blur: CGFloat) -> CGImage {
        let size = CGSize(width: 256, height: 256)
        let drawn = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            for row in 0..<16 {
                for column in 0..<16 where (row + column).isMultiple(of: 2) {
                    context.fill(CGRect(x: column * 16, y: row * 16, width: 16, height: 16))
                }
            }
        }
        guard blur > 0 else { return drawn.cgImage! }
        let input = CIImage(cgImage: drawn.cgImage!)
        let filter = CIFilter(name: "CIGaussianBlur")!
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(blur, forKey: "inputRadius")
        let output = filter.outputImage!.cropped(to: input.extent)
        return CIContext().createCGImage(output, from: input.extent)!
    }

    @Test func blurCostsSharpness() {
        let sharp = FrameSharpness.score(of: Self.checkerboard(blur: 0))
        let soft = FrameSharpness.score(of: Self.checkerboard(blur: 3))
        let softer = FrameSharpness.score(of: Self.checkerboard(blur: 8))
        #expect(sharp > soft)
        #expect(soft > softer)
    }

    /// A picture of nothing is not in focus, it is empty. Either way it is not
    /// worth signing, and it must not score above a real frame.
    @Test func aFlatFrameScoresNothing() {
        let flat = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        }.cgImage!
        #expect(FrameSharpness.score(of: flat) < 1)
    }

    @Test func aBufferTooSmallToHaveAnInteriorScoresNothing() {
        #expect(FrameSharpness.score(gray: [1, 2, 3, 4], width: 2, height: 2) == 0)
        #expect(FrameSharpness.score(gray: [], width: 0, height: 0) == 0)
    }
}

@Suite struct FramePolicyTests {
    /// Thirty frames a second arrive. Reading text on all of them would heat
    /// the phone and read nothing better, because the name does not move while
    /// he holds the card.
    @Test func expensiveWorkIsRationed() {
        var policy = FramePolicy(textInterval: 0.25, cardInterval: 0.1)
        let start = Date()

        let first = policy.decide(at: start)
        #expect(first.readText)
        #expect(first.findCard)

        // A frame 1/30 s later: too soon for either.
        let next = policy.decide(at: start.addingTimeInterval(1.0 / 30))
        #expect(!next.readText)
        #expect(!next.findCard)

        // A tenth of a second on, the card is worth finding again but the text
        // is not worth reading again.
        let later = policy.decide(at: start.addingTimeInterval(0.11))
        #expect(!later.readText)
        #expect(later.findCard)

        let muchLater = policy.decide(at: start.addingTimeInterval(0.3))
        #expect(muchLater.readText)
        #expect(muchLater.findCard)
    }

    @Test func aSoftFrameIsNeverSigned() {
        let policy = FramePolicy(minimumSharpness: 25, goodEnoughSharpness: 160)
        #expect(!policy.shouldSign(sharpness: 10, bestSoFar: 0))
        #expect(policy.shouldSign(sharpness: 30, bestSoFar: 0))
    }

    /// Signing costs a feature print. Doing it again for a frame no better than
    /// the one already signed buys nothing.
    @Test func onlyAnImprovementIsWorthSigning() {
        let policy = FramePolicy(minimumSharpness: 25, goodEnoughSharpness: 160)
        #expect(!policy.shouldSign(sharpness: 40, bestSoFar: 50))
        #expect(policy.shouldSign(sharpness: 60, bestSoFar: 50))
        // Past the point where better is not going to change the answer.
        #expect(!policy.shouldSign(sharpness: 300, bestSoFar: 200))
    }
}

@Suite struct SharpestSignatureTests {
    private func reading(sharpness: Double, seed: UInt64, number: String? = "125/197") -> ScanObservation {
        var observation = ScanObservation(number: number)
        observation.artDescriptor = Fixture.artDescriptor(seed: seed)
        observation.artSharpness = sharpness
        return observation
    }

    /// Signatures are not votes. A blurred look and a sharp look at one card do
    /// not average into a better reading of the artwork; the sharp one is
    /// simply right, however few frames caught it.
    @Test func theSharpestSignatureWinsNotTheMostCommon() {
        var accumulator = ObservationAccumulator()
        let now = Date()
        accumulator.add(reading(sharpness: 20, seed: 1), now: now)
        accumulator.add(reading(sharpness: 25, seed: 1), now: now)
        accumulator.add(reading(sharpness: 30, seed: 1), now: now)
        // One good look, late and alone.
        accumulator.add(reading(sharpness: 180, seed: 2), now: now)

        let merged = accumulator.merged(now: now)
        #expect(merged.artDescriptor == Fixture.artDescriptor(seed: 2))
        #expect(merged.artSharpness == 180)
    }

    /// Most frames carry a signature and no words, because text runs on its own
    /// slower cadence. Dropping those frames would throw away every sharp look
    /// at the card.
    @Test func aFrameWithOnlyASignatureStillCounts() {
        var accumulator = ObservationAccumulator()
        let now = Date()
        var signatureOnly = ScanObservation()
        signatureOnly.artDescriptor = Fixture.artDescriptor(seed: 3)
        signatureOnly.artSharpness = 90
        accumulator.add(signatureOnly, now: now)
        accumulator.add(ScanObservation(number: "125/197", name: "Charizard ex"), now: now)

        let merged = accumulator.merged(now: now)
        #expect(merged.number == "125/197")
        #expect(merged.artDescriptor == Fixture.artDescriptor(seed: 3))
    }

    /// A frame with nothing in it at all is still nothing.
    @Test func anEmptyFrameIsStillIgnored() {
        var accumulator = ObservationAccumulator()
        accumulator.add(ScanObservation())
        #expect(accumulator.merged().isEmpty)
        #expect(accumulator.merged().artDescriptor == nil)
    }

    /// The signature expires with the window, like every other reading. The
    /// card he is holding now is not the card he held two seconds ago.
    @Test func aSignatureLeavesTheWindowWithEverythingElse() {
        var accumulator = ObservationAccumulator()
        let start = Date()
        accumulator.add(reading(sharpness: 200, seed: 4), now: start)
        let merged = accumulator.merged(now: start.addingTimeInterval(5))
        #expect(merged.artDescriptor == nil)
    }
}
