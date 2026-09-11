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

    /// Pull the four corners back to a rectangle and render at the fixed size.
    static func flatten(_ image: CGImage, to rectangle: VNRectangleObservation) -> CGImage? {
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
