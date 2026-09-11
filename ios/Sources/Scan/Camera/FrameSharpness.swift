import Accelerate
import CoreGraphics
import Foundation

/// How sharp a frame is, as one number.
///
/// The measurement said blur is the only thing that really hurts artwork
/// matching: perspective costs nothing, colour and glare cost five points, and
/// blur costs thirteen. Owning the camera means we no longer have to sign
/// whatever frame happens to arrive — we can sign the sharpest one of the last
/// second and throw the rest away.
///
/// The measure is the variance of the Laplacian, which is the standard focus
/// score: a sharp edge gives a large second derivative, a blurred one gives a
/// small one, and a flat wall gives none at all. It is computed on a fixed-size
/// grey copy so two frames are always comparable.
enum FrameSharpness {
    /// The side the frame is reduced to before measuring. Fixed, because the
    /// score depends on scale and two frames must be judged the same way.
    static let workingSide = 256

    /// Variance of the Laplacian over a greyscale buffer. Larger is sharper.
    ///
    /// Zero for a buffer too small to have an interior, and zero for a flat
    /// one, which is correct: a picture of nothing is not in focus, it is
    /// empty, and either way it is not worth signing.
    static func score(gray: [UInt8], width: Int, height: Int) -> Double {
        guard width > 2, height > 2, gray.count >= width * height else { return 0 }
        var sum = 0.0
        var sumOfSquares = 0.0
        var count = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                // The four-neighbour Laplacian. Cheap, and the only thing that
                // matters is how much it varies.
                let response = Double(gray[index - width])
                    + Double(gray[index + width])
                    + Double(gray[index - 1])
                    + Double(gray[index + 1])
                    - 4 * Double(gray[index])
                sum += response
                sumOfSquares += response * response
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        return max(0, sumOfSquares / count - mean * mean)
    }

    /// The sharpness of an image, reduced to grey at the working size first.
    static func score(of image: CGImage) -> Double {
        guard let (gray, width, height) = grayscale(image) else { return 0 }
        return score(gray: gray, width: width, height: height)
    }

    /// A greyscale copy at the working size. One byte a pixel, no padding.
    static func grayscale(_ image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        let longest = max(image.width, image.height)
        guard longest > 0 else { return nil }
        let scale = Double(workingSide) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))

        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return (pixels, width, height)
    }
}
