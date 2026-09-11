import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

/// Reads one camera frame: the card in it, the words on it, and its signature.
///
/// One buffer, one pass. The old scanner read text from the live preview and
/// pixels from a separate photograph, which were two different moments of two
/// different exposures; a signature taken from one and a number from the other
/// describe different looks at the card. Here everything comes off the same
/// frame, so a match is a match of one photograph.
///
/// Runs off the main actor, on the capture queue.
struct FrameReader {
    /// What one frame yielded. Any part may be missing: the card may be out of
    /// view, the words unreadable, the frame too soft to sign.
    struct Reading {
        var observation = ScanObservation()
        /// Where the card sat, normalised, origin bottom left. Drawn in the
        /// viewfinder so he can see what the scanner is looking at.
        var cardCorners: [CGPoint]?
        var sharpness: Double = 0
    }

    var policy: FramePolicy

    private let context = CIContext(options: [.useSoftwareRenderer: false])

    init(policy: FramePolicy = FramePolicy()) {
        self.policy = policy
    }

    /// Read a frame according to what the policy allows, and what the cheap
    /// work finds.
    ///
    /// `bestSharpness` is the best already signed for the card in view, so a
    /// frame no better than it is not signed again.
    mutating func read(
        _ pixels: CVPixelBuffer,
        at now: Date,
        bestSharpness: Double,
        isFocusing: Bool
    ) -> Reading {
        var reading = Reading()
        let decision = policy.decide(at: now)
        guard decision.readText || decision.findCard else { return reading }

        let image = CIImage(cvPixelBuffer: pixels)
        guard let frame = context.createCGImage(image, from: image.extent) else { return reading }

        // Barcodes first and cheaply: a slab is read by its label, not its art,
        // and a graded card has no artwork the catalog holds anyway.
        if decision.readText, let slab = readSlab(frame) {
            reading.observation.certNumber = slab.cert
            reading.observation.grader = slab.grader
            return reading
        }

        if decision.readText {
            reading.observation = readText(frame)
        }

        guard decision.findCard else { return reading }

        // The lens is moving, so whatever this frame shows is in transit. Find
        // the card for the outline, but do not sign it.
        reading.sharpness = FrameSharpness.score(of: frame)
        guard let card = try? CardRectifier.rectify(frame) else { return reading }
        reading.cardCorners = card.corners

        guard !isFocusing, policy.shouldSign(sharpness: reading.sharpness, bestSoFar: bestSharpness) else {
            return reading
        }
        if let raw = try? CardArtDescriptor.featurePrint(of: card.image),
           let signature = CardArtDescriptor.make(fromRaw: raw) {
            reading.observation.artDescriptor = signature
            reading.observation.artSharpness = reading.sharpness
        }
        return reading
    }

    // MARK: - The requests

    private func readText(_ frame: CGImage) -> ScanObservation {
        guard let items = try? StillFrameReader.readNow(frame, longestSide: StillFrameReader.workingSize) else {
            return ScanObservation()
        }
        return FrameInterpreter.interpret(items).observation
    }

    /// PSA and CGC put the cert number in a barcode on the label.
    private func readSlab(_ frame: CGImage) -> (cert: String, grader: String)? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr, .code128, .code39, .pdf417, .dataMatrix]
        guard (try? VNImageRequestHandler(cgImage: frame, options: [:]).perform([request])) != nil else { return nil }
        for observation in request.results ?? [] {
            guard let payload = observation.payloadStringValue,
                  let found = FrameInterpreter.cert(fromBarcode: payload)
            else { continue }
            return found
        }
        return nil
    }
}
