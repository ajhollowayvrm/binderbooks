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
        /// The frame those corners are normalised against. The viewfinder needs
        /// it to place them, because the preview shows the frame cropped to
        /// fill a differently shaped view.
        var frameSize: CGSize = .zero
        var sharpness: Double = 0
    }

    var policy: FramePolicy

    /// The catalogue he said he is scanning. Vision is given that language and
    /// no other: every extra alphabet is another thing for glare and foil to be
    /// misread as, and one invented kana is enough to move a card into the
    /// wrong catalogue.
    var language: ScanLanguage = .english

    private let context = CIContext(options: [.useSoftwareRenderer: false])

    init(policy: FramePolicy = FramePolicy(), language: ScanLanguage = .english) {
        self.policy = policy
        self.language = language
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
        reading.frameSize = CGSize(width: frame.width, height: frame.height)

        // Barcodes first and cheaply: a slab is read by its label, not its art,
        // and a graded card has no artwork the catalog holds anyway.
        if decision.readText, let slab = readSlab(frame) {
            reading.observation.certNumber = slab.cert
            reading.observation.grader = slab.grader
            return reading
        }

        // Find the card once, and read everything from inside it.
        //
        // The words used to be read off the whole frame. A frame is his desk,
        // the binder page, the next card in the chute and the card he is
        // holding, and Vision reads every word in it with no idea which
        // surface each one came from — which is how "Resistance Gym" off a
        // neighbouring card was logged twice while he was holding a Dedenne.
        // Nothing outside the card's own quadrilateral is read now.
        let rectangle = try? CardRectifier.detect(frame)
        if let rectangle {
            reading.observation.sawCard = true
            reading.cardCorners = [
                rectangle.topLeft, rectangle.topRight,
                rectangle.bottomRight, rectangle.bottomLeft,
            ]
        }

        if decision.readText, let rectangle {
            // At the card's own resolution, not the signature's. A signature
            // is taken at 448 by 627, where the collector number is eight
            // pixels of text and unreadable.
            let size = CardRectifier.readingSize(for: rectangle, in: frame)
            if let card = CardRectifier.flatten(frame, to: rectangle, size: size) {
                var words = readText(card)
                words.sawCard = true
                reading.observation = words
            }
        }

        guard decision.findCard else { return reading }

        // Scored whether or not a card was found, because the frames with no
        // card in them are the ones worth telling apart: an empty chute scores
        // nothing, and a card held so close that its edges leave the frame
        // scores like any other card. The second is a card he is trying to
        // scan, and it reads nothing until he moves back.
        reading.sharpness = FrameSharpness.score(of: frame)

        // The lens is moving, so whatever this frame shows is in transit. The
        // outline is drawn from it, but it is not signed.
        guard let rectangle else { return reading }
        guard !isFocusing, policy.shouldSign(sharpness: reading.sharpness, bestSoFar: bestSharpness) else {
            return reading
        }
        guard let card = CardRectifier.flatten(frame, to: rectangle) else { return reading }
        if let raw = try? CardArtDescriptor.featurePrint(of: card),
           let signature = CardArtDescriptor.make(fromRaw: raw) {
            reading.observation.artDescriptor = signature
            reading.observation.artSharpness = reading.sharpness
            // The sharpest frame so far is also worth keeping as a photo, in
            // case he marks the card S-Chinese and it becomes the card's art.
            if let photo = CardRectifier.flatten(frame, to: rectangle, size: CardRectifier.readingSize(for: rectangle, in: frame)) {
                reading.observation.photoJPEG = CardPhotoStore.jpeg(photo)
            }
        }
        return reading
    }

    // MARK: - The requests

    private func readText(_ frame: CGImage) -> ScanObservation {
        guard let items = try? StillFrameReader.readNow(
            frame,
            languages: language.recognitionLanguages,
            longestSide: StillFrameReader.workingSize
        ) else {
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
