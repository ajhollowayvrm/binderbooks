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
        /// How sure the detector was. The viewfinder draws a confident outline
        /// solid and a loose one dashed, so he can see which he is getting.
        var located: CardRectifier.Located = .none
    }

    var policy: FramePolicy

    /// When the current card first appeared with nothing signed for it. Drives
    /// `FramePolicy.shouldSignBestEffort`, and is cleared the moment anything
    /// is signed or the card leaves.
    private var unsignedSince: Date?

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
        let located = (try? CardRectifier.locate(frame)) ?? CardRectifier.Located.none
        reading.located = located
        let rectangle = located.rectangle
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

        reading.sharpness = FrameSharpness.score(of: frame)

        // No card at any tier, and the frame is full of detail. He is holding
        // it too close for its edges to fit, and every path above has just
        // read nothing. Read the guide box instead of going silent.
        if decision.readText, rectangle == nil,
           policy.looksFilledButUnread(sawCard: false, sharpness: reading.sharpness),
           let crop = CardRectifier.guideCrop(frame) {
            var words = readText(crop)
            if !words.isEmpty {
                words.readFromGuideCrop = true
                // Deliberately not `sawCard`: nothing found a card. The words
                // came from where a card is supposed to be, which is weaker,
                // and the loop treats them as weaker.
                reading.observation = words
            }
        }

        guard decision.findCard else { return reading }

        // The lens is moving, so whatever this frame shows is in transit. The
        // outline is drawn from it, but it is not signed.
        guard let rectangle else {
            unsignedSince = nil
            return reading
        }

        // How long this card has been in view with nothing signed for it.
        if bestSharpness > 0 {
            unsignedSince = nil
        } else if unsignedSince == nil {
            unsignedSince = now
        }
        let unsignedFor = unsignedSince.map { now.timeIntervalSince($0) } ?? 0

        guard !isFocusing else { return reading }
        let ordinary = policy.shouldSign(sharpness: reading.sharpness, bestSoFar: bestSharpness)
        // A dim chute never clears the ordinary bar, and a card with no
        // signature at all loses the one signal that survives bad words.
        let bestEffort = !ordinary && policy.shouldSignBestEffort(
            sharpness: reading.sharpness,
            bestSoFar: bestSharpness,
            unsignedFor: unsignedFor
        )
        guard ordinary || bestEffort else { return reading }

        guard let card = CardRectifier.flatten(frame, to: rectangle) else { return reading }
        if let raw = try? CardArtDescriptor.featurePrint(of: card),
           let signature = CardArtDescriptor.make(fromRaw: raw) {
            reading.observation.artDescriptor = signature
            reading.observation.artSharpness = reading.sharpness
            // A signature off a loose detection is no better founded than one
            // off a soft frame: both are "this is probably the card".
            reading.observation.artIsBestEffort = bestEffort || !located.isConfident
            unsignedSince = nil
            // The sharpest frame so far is also worth keeping as a photo, in
            // case he marks the card S-Chinese and it becomes the card's art.
            if let photo = CardRectifier.flatten(frame, to: rectangle, size: CardRectifier.readingSize(for: rectangle, in: frame)) {
                reading.observation.photoJPEG = CardPhotoStore.jpeg(photo)
            }
        }
        return reading
    }

    /// The manual shutter. Reads this one frame with every gate off.
    ///
    /// The live loop is careful on purpose: it reads text four times a second,
    /// only inside a card it is sure of, and signs only sharp frames. When he
    /// presses the shutter he has already decided the card is there, so none
    /// of that applies. The card is read inside its outline when one is found,
    /// then from the guide box, then from the whole frame, until a number
    /// comes back. The artwork is signed from the best of those, however soft.
    func readForced(_ pixels: CVPixelBuffer) -> ScanObservation {
        let image = CIImage(cvPixelBuffer: pixels)
        guard let frame = context.createCGImage(image, from: image.extent) else { return ScanObservation() }

        if let slab = readSlab(frame) {
            var slabReading = ScanObservation()
            slabReading.certNumber = slab.cert
            slabReading.grader = slab.grader
            return slabReading
        }

        let located = (try? CardRectifier.locate(frame)) ?? CardRectifier.Located.none
        var views: [CGImage] = []
        var art: CGImage?
        if let rectangle = located.rectangle {
            if let card = CardRectifier.flatten(frame, to: rectangle, size: CardRectifier.readingSize(for: rectangle, in: frame)) {
                views.append(card)
            }
            art = CardRectifier.flatten(frame, to: rectangle)
        }
        if let crop = CardRectifier.guideCrop(frame) {
            views.append(crop)
            art = art ?? crop
        }
        views.append(frame)

        // The first view to read a number wins. Failing that, the first to
        // read anything at all.
        var observation = ScanObservation()
        for view in views {
            let words = readText(view)
            if words.number != nil {
                observation = words
                break
            }
            if observation.isEmpty { observation = words }
        }
        observation.sawCard = true
        observation.readFromGuideCrop = false

        if let art,
           let raw = try? CardArtDescriptor.featurePrint(of: art),
           let signature = CardArtDescriptor.make(fromRaw: raw) {
            observation.artDescriptor = signature
            observation.artSharpness = FrameSharpness.score(of: frame)
            observation.artIsBestEffort = !located.isConfident
            observation.photoJPEG = CardPhotoStore.jpeg(art)
        }
        return observation
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
