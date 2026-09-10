import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import BinderBooks

/// Reading a still, end to end: draw a card, photograph nothing, read the
/// drawing, and check the interpreter picks the name and the number off it.
///
/// The live scanner failed on a real Sableye twice — once reading the attack
/// name, once misreading the set total by a digit. A still is the answer, and
/// this is the proof that the still path picks the right two strings.
@Suite struct StillFrameReaderTests {
    /// A card: name top left, HP top right, an attack across the middle, and
    /// the collector number bottom left, which is where a Pokémon card puts it.
    static func drawCard(name: String, hp: String, attack: String, number: String, scale: CGFloat = 1, numberSize: CGFloat = 30) -> CGImage {
        let size = CGSize(width: 734 * scale, height: 1024 * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            func draw(_ text: String, at point: CGPoint, size fontSize: CGFloat) {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: fontSize),
                    .foregroundColor: UIColor.black,
                ]
                text.draw(at: point, withAttributes: attributes)
            }

            draw(name, at: CGPoint(x: 60 * scale, y: 45 * scale), size: 58 * scale)
            draw(hp, at: CGPoint(x: 560 * scale, y: 52 * scale), size: 44 * scale)
            draw(attack, at: CGPoint(x: 240 * scale, y: 610 * scale), size: 46 * scale)
            draw(number, at: CGPoint(x: 60 * scale, y: 950 * scale), size: numberSize * scale)
        }
        return image.cgImage!
    }

    private func interpret(_ image: CGImage) async throws -> ScanObservation {
        let items = try await StillFrameReader.read(image, languages: ["en"])
        return FrameInterpreter.interpret(items).observation
    }

    @Test func aStillYieldsTheNameAndTheNumber() async throws {
        let card = Self.drawCard(name: "Sableye", hp: "HP 80", attack: "Scratch", number: "070/196")
        let observation = try await interpret(card)
        #expect(observation.name == "Sableye")
        #expect(observation.number == "070/196")
    }

    /// The failure that started this. The attack sits below the art and reads
    /// at the same size as the name, so only its position rules it out.
    @Test func theAttackNameNeverWinsOverTheCardName() async throws {
        let card = Self.drawCard(name: "Sableye", hp: "HP 80", attack: "Scratch", number: "070/196")
        let observation = try await interpret(card)
        #expect(observation.name != "Scratch")
    }

    @Test func aBigPhotoIsCutDownBeforeVisionSeesIt() throws {
        // The renderer multiplies by the screen scale, so this is several
        // thousand pixels wide however the simulator is configured.
        let big = Self.drawCard(name: "Sableye", hp: "HP 80", attack: "Scratch", number: "070/196", scale: 4)
        #expect(max(big.width, big.height) > Int(StillFrameReader.workingSize))

        let smaller = try #require(StillFrameReader.downscaled(big))
        #expect(max(smaller.width, smaller.height) == Int(StillFrameReader.workingSize))
        #expect(smaller.width < big.width)

        // Already small enough: left alone rather than resampled for nothing.
        #expect(StillFrameReader.downscaled(big, to: 50_000) == nil)
    }

    /// The cut must not cost a digit. A misread total is what produced a
    /// Mawile V from a Sableye.
    @Test func aPhoneSizedPhotoStillReadsExactly() async throws {
        let big = Self.drawCard(name: "Sableye", hp: "HP 80", attack: "Scratch", number: "070/196", scale: 4)
        let observation = try await interpret(big)
        #expect(observation.name == "Sableye")
        #expect(observation.number == "070/196")
    }

    /// Why the retry exists. The collector number is the smallest print on a
    /// card, and the downscale that makes the first pass fast is what loses it.
    @Test func aTinyNumberIsFoundAtFullResolution() async throws {
        let card = Self.drawCard(
            name: "Sableye", hp: "HP 80", attack: "Scratch", number: "070/196",
            scale: 4, numberSize: 7
        )
        let full = try await StillFrameReader.read(card, languages: ["en"], longestSide: nil)
        let observation = FrameInterpreter.interpret(full).observation
        #expect(observation.number == "070/196")
    }

    /// The digit that produced a Mawile V. A still must read the total exactly.
    @Test func theSetTotalSurvivesIntact() async throws {
        for number in ["070/196", "114/084", "004/102"] {
            let card = Self.drawCard(name: "Sableye", hp: "HP 80", attack: "Scratch", number: number)
            let observation = try await interpret(card)
            #expect(observation.number == number, "read \(observation.number ?? "nothing") for \(number)")
        }
    }

}
