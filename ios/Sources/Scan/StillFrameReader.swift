import CoreGraphics
import Foundation
import Vision

/// Reads text off a still photo.
///
/// The live scanner reads a small, moving, video-rate frame and it misses
/// things: it read an attack name instead of a card name, and it read a set
/// total of 195 off a card printed 196. A still is a different proposition —
/// full sensor resolution, no motion, and no 30-per-second budget — so Vision
/// can run `.accurate` with language correction and take as long as it needs.
///
/// This is still OCR. It reads the name and the number, the same two strings
/// docs/00 decision 8 settled on, and it adds no model and no dependency.
enum StillFrameReader {
    /// The longest side Vision is given.
    ///
    /// A 48-megapixel photo costs seconds to read and buys nothing: a card
    /// filling a third of the frame still lands about 500 pixels wide here,
    /// which is far more than text recognition needs.
    static let workingSize: CGFloat = 1600

    /// Every text line in the image, in the shape the interpreter wants.
    ///
    /// Runs off the main actor. Vision's `perform` is synchronous, and on the
    /// main thread it freezes the viewfinder for as long as it takes — which is
    /// the lag he felt after tapping the shutter.
    /// `longestSide` nil reads the image at full resolution. Slower, and worth
    /// it only when the first pass missed the collector number.
    static func read(_ image: CGImage, languages: [String] = ["en", "ja"], longestSide: CGFloat? = workingSize) async throws -> [RecognizedText] {
        try await Task.detached(priority: .userInitiated) {
            try readNow(image, languages: languages, longestSide: longestSide)
        }.value
    }

    static func readNow(_ image: CGImage, languages: [String] = ["en", "ja"], longestSide: CGFloat? = workingSize) throws -> [RecognizedText] {
        let source = longestSide.flatMap { downscaled(image, to: $0) } ?? image
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        // A collector number is not a word. Without this, language correction
        // rewrites "070/196" into something it likes better.
        request.customWords = []

        let handler = VNImageRequestHandler(cgImage: source, options: [:])
        try handler.perform([request])
        return items(from: request.results ?? [])
    }

    /// Nil when the image is already small enough, so the caller uses it as is.
    static func downscaled(_ image: CGImage, to longestSide: CGFloat = workingSize) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let longest = max(width, height)
        guard longest > longestSide else { return nil }
        let scale = longestSide / longest
        let target = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        guard let space = image.colorSpace,
              let context = CGContext(
                data: nil,
                width: Int(target.width),
                height: Int(target.height),
                bitsPerComponent: image.bitsPerComponent,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: image.bitmapInfo.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: target))
        return context.makeImage()
    }

    /// Vision's boxes to the interpreter's top-down fractions. Vision puts the
    /// origin at the bottom left; the interpreter counts down from the top,
    /// because that is where a card's name is.
    static func items(from observations: [VNRecognizedTextObservation]) -> [RecognizedText] {
        observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedText(
                id: UUID(),
                transcript: candidate.string,
                top: 1 - observation.boundingBox.maxY,
                height: observation.boundingBox.height
            )
        }
    }
}
