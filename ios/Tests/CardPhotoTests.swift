import CoreGraphics
import Foundation
import Testing
@testable import BinderBooks

/// The listing photo a Chinese session keeps of each card.
@Suite struct CardPhotoTests {
    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    @Test func thePhotoIsAJPEG() throws {
        let data = try #require(CardPhotoStore.jpeg(try image(width: 1000, height: 1400)))
        #expect(data.prefix(2) == Data([0xFF, 0xD8]))
    }

    /// The same rule as the artwork signature: the sharpest frame that took a
    /// photo. A sharper frame with no photo does not take the photo away.
    @Test func theSharpestPhotoWins() {
        var accumulator = ObservationAccumulator()
        let now = Date()
        var soft = ScanObservation(number: "001/128")
        soft.artDescriptor = [1]
        soft.artSharpness = 40
        soft.photoJPEG = Data([1])
        var sharp = ScanObservation(number: "001/128")
        sharp.artDescriptor = [2]
        sharp.artSharpness = 120
        sharp.photoJPEG = Data([2])
        var signedOnly = ScanObservation()
        signedOnly.artDescriptor = [3]
        signedOnly.artSharpness = 200
        accumulator.add(soft, now: now)
        accumulator.add(sharp, now: now.addingTimeInterval(0.1))
        accumulator.add(signedOnly, now: now.addingTimeInterval(0.2))

        let merged = accumulator.merged(now: now.addingTimeInterval(0.3))
        #expect(merged.photoJPEG == Data([2]))
        #expect(merged.artDescriptor == [3])
    }
}
