import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The photo he took of a card, or picked for it, when the card has no
/// catalog product to draw art from — an S-Chinese card today, maybe
/// another untracked kind later.
///
/// One JPEG per card, named by the card's id, in Application Support. The
/// collection store does not hold it, and the collection export does not
/// carry it.
enum CardPhotoStore {
    static let quality: CGFloat = 0.85

    static var directory: URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("CardPhotos", isDirectory: true)
    }

    static func url(for id: UUID) -> URL? {
        directory?.appendingPathComponent("\(id.uuidString).jpg")
    }

    /// Nil when the card has no photo.
    static func existingURL(for id: UUID) -> URL? {
        guard let url = url(for: id), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func save(_ jpeg: Data, for id: UUID) throws {
        guard let directory, let url = url(for: id) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try jpeg.write(to: url, options: .atomic)
    }

    /// "Same card again" logs a second copy of the card in the chute, and the
    /// copy takes the same photo.
    static func copy(from source: UUID, to target: UUID) {
        guard let from = existingURL(for: source), let to = url(for: target) else { return }
        try? FileManager.default.copyItem(at: from, to: to)
    }

    static func remove(_ ids: [UUID]) {
        for id in ids {
            if let url = existingURL(for: id) { try? FileManager.default.removeItem(at: url) }
        }
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
