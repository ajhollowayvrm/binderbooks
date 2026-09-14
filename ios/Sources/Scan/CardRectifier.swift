import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Finds the card in a frame and flattens it.
///
/// This runs before anything looks at pixels. A frame holds his desk, his
/// keyboard, the next card in the stack and a lamp, and a signature taken over
/// all that describes the room. It also holds the card at whatever angle he was
/// holding it, and artwork photographed on a slant does not compare against a
/// reference scanned flat.
///
/// Vision finds the quadrilateral, Core Image pulls its corners back to a
/// rectangle, and what comes out is the card alone, upright, at a fixed size.
enum CardRectifier {
    /// A trading card is 2.5 by 3.5 inches. Vision measures the ratio as the
    /// short side over the long one, so a card is 0.714.
    static let cardAspect: Float = 2.5 / 3.5

    /// How far from that ratio a detection may sit. Perspective shortens the
    /// far edge, so the tolerance is wide enough for a card held in the hand
    /// and narrow enough to reject a phone, a book, or the desk itself.
    static let aspectTolerance: Float = 0.13

    /// The rectified card. Wide enough that the fine print survives, small
    /// enough that Vision's own downscale does the rest.
    static let outputSize = CGSize(width: 448, height: 627)

    /// The long side of the card when it is flattened for **reading**.
    ///
    /// Reading is not signing. A signature is taken at `outputSize`, where the
    /// artwork survives and the fine print does not have to. The collector
    /// number is three millimetres of ink at the bottom edge, and at 627 pixels
    /// tall it is about eight pixels of text, which Vision cannot read. This
    /// size keeps it legible without asking Vision to read a whole desk.
    static let readingLongSide: CGFloat = 1400

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    struct Rectified {
        var image: CGImage
        /// Vision's confidence in the quadrilateral, 0 to 1.
        var confidence: Float
        /// Where the card sat in the frame, normalised, origin bottom left.
        /// The viewfinder draws this so he can see what was read.
        var corners: [CGPoint]
    }

    /// The card in this frame, or nil when no card-shaped thing is in it.
    ///
    /// Nil is a normal answer, not a failure: he photographs a stack, a sleeve
    /// glares, a card sits half out of frame. The caller falls back to the text
    /// it already has.
    static func rectify(_ image: CGImage) throws -> Rectified? {
        guard let rectangle = try detect(image) else { return nil }
        guard let flattened = flatten(image, to: rectangle) else { return nil }
        return Rectified(
            image: flattened,
            confidence: rectangle.confidence,
            corners: [
                rectangle.topLeft, rectangle.topRight,
                rectangle.bottomRight, rectangle.bottomLeft,
            ]
        )
    }

    /// The most card-like rectangle in the frame, largest first.
    ///
    /// Largest, not most confident: he holds the card he is logging closest to
    /// the lens, and the crisp rectangle in the background is the binder page.
    static func detect(_ image: CGImage) throws -> VNRectangleObservation? {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = VNAspectRatio(cardAspect - aspectTolerance)
        request.maximumAspectRatio = VNAspectRatio(cardAspect + aspectTolerance)
        // A card fills a good part of the viewfinder when he is scanning one.
        // Below this the detection is something else in the room.
        request.minimumSize = 0.25
        request.minimumConfidence = 0.6
        // A card has square corners. The default tolerance admits trapezoids
        // that no card held by a human ever makes.
        request.quadratureTolerance = 25
        request.maximumObservations = 8

        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let found = request.results ?? []
        return found.max { area(of: $0) < area(of: $1) }
    }

    private static func area(of rectangle: VNRectangleObservation) -> CGFloat {
        rectangle.boundingBox.width * rectangle.boundingBox.height
    }

    /// The card alone, flattened at reading resolution.
    ///
    /// Everything that reads words off a frame must read this and not the
    /// frame. A camera frame holds the card he is logging, the next card in the
    /// chute, the binder page behind it and his desk, and Vision reads all of
    /// it: that is how "Resistance Gym" off a neighbouring card and "Tail
    /// Smack" off this one's own attack line became cards in the ledger. The
    /// crop is the fix, because a word that is not on the card cannot be read
    /// from it.
    ///
    /// Nil when no card is in the frame. The caller decides what to do then,
    /// and the honest answer is usually nothing.
    static func rectifyForReading(_ image: CGImage) throws -> CGImage? {
        guard let rectangle = try detect(image) else { return nil }
        return flatten(image, to: rectangle, size: readingSize(for: rectangle, in: image))
    }

    /// How large to render the card for reading: its own pixel size, capped.
    ///
    /// Capped because a card filling the frame of a 48-megapixel sensor gains
    /// nothing from being rendered at that size and costs seconds. Its own size
    /// rather than a fixed one because upsampling a card held far from the lens
    /// invents no detail and only makes Vision slower.
    static func readingSize(for rectangle: VNRectangleObservation, in image: CGImage) -> CGSize {
        let box = rectangle.boundingBox
        let pixelHeight = box.height * CGFloat(image.height)
        let pixelWidth = box.width * CGFloat(image.width)
        let longest = max(pixelHeight, pixelWidth, 1)
        let height = min(readingLongSide, longest)
        return CGSize(
            width: max(1, (height * CGFloat(cardAspect)).rounded()),
            height: max(1, height.rounded())
        )
    }

    /// Pull the four corners back to a rectangle and render at the fixed size.
    static func flatten(_ image: CGImage, to rectangle: VNRectangleObservation) -> CGImage? {
        flatten(image, to: rectangle, size: outputSize)
    }

    /// Pull the four corners back to a rectangle and render at the given size.
    static func flatten(_ image: CGImage, to rectangle: VNRectangleObservation, size outputSize: CGSize) -> CGImage? {
        let source = CIImage(cgImage: image)
        let extent = source.extent

        // Vision reports corners normalised with the origin at the bottom left.
        // Core Image counts the same way, so this is a scale and nothing more.
        func point(_ normalised: CGPoint) -> CIVector {
            CIVector(
                x: extent.origin.x + normalised.x * extent.width,
                y: extent.origin.y + normalised.y * extent.height
            )
        }

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(source, forKey: kCIInputImageKey)
        filter.setValue(point(rectangle.topLeft), forKey: "inputTopLeft")
        filter.setValue(point(rectangle.topRight), forKey: "inputTopRight")
        filter.setValue(point(rectangle.bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(point(rectangle.bottomRight), forKey: "inputBottomRight")
        guard let corrected = filter.outputImage else { return nil }

        // To the fixed size, so every signature is taken at one scale.
        let scaleX = outputSize.width / corrected.extent.width
        let scaleY = outputSize.height / corrected.extent.height
        let scaled = corrected.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        return context.createCGImage(scaled, from: CGRect(origin: .zero, size: outputSize))
    }
}
