import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UIKit
import UniformTypeIdentifiers
import Vision

/// A receipt that is not saved yet: the bytes to store, and the text the app
/// read off it.
struct ReceiptFile: Identifiable, Equatable {
    var id = UUID()
    var kind: Receipt.Kind
    var data: Data
    var fileName: String = ""
    var text: String = ""

    /// The lines the parser reads.
    var lines: [String] { text.components(separatedBy: .newlines) }
}

/// Turns a photo, a scan, or a file into a `ReceiptFile`.
///
/// The text is read from the original, at full size. The copy that is stored
/// is smaller: every receipt travels in the backup export, so a 12-megapixel
/// photo of a receipt costs him in every backup he makes.
enum ReceiptReader {
    /// The short side of a stored image. A long screenshot keeps its length,
    /// so its text stays readable.
    static let storedShortSide: CGFloat = 1500
    static let jpegQuality: CGFloat = 0.6

    /// A photo, a screenshot, or a page from the document camera.
    static func image(_ data: Data, fileName: String = "") async -> ReceiptFile? {
        guard let picture = UIImage(data: data) else { return nil }
        return await image(picture, fileName: fileName)
    }

    static func image(_ image: UIImage, fileName: String = "") async -> ReceiptFile? {
        guard let stored = storedJPEG(image) else { return nil }
        let text = (try? await read(image)) ?? ""
        return ReceiptFile(kind: .image, data: stored, fileName: fileName, text: text)
    }

    /// A PDF. An online invoice carries its own text. A scanned PDF has none,
    /// so its first page is read as an image.
    static func pdf(_ data: Data, fileName: String = "") async -> ReceiptFile? {
        guard let document = PDFDocument(data: data) else { return nil }
        var text = document.string ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let page = document.page(at: 0) {
            let bounds = page.bounds(for: .mediaBox)
            let image = page.thumbnail(of: CGSize(width: bounds.width * 3, height: bounds.height * 3), for: .mediaBox)
            text = (try? await read(image)) ?? ""
        }
        return ReceiptFile(kind: .pdf, data: data, fileName: fileName, text: text)
    }

    /// A file from the Files app: a PDF or an image.
    static func file(at url: URL) async -> ReceiptFile? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let name = url.lastPathComponent
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
            return await pdf(data, fileName: name)
        }
        return await image(data, fileName: name)
    }

    // MARK: - Text

    /// The rows of text on the image, top to bottom. Runs off the main actor,
    /// because Vision's `perform` is synchronous.
    static func read(_ image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage ?? render(image).cgImage else { return "" }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:]).perform([request])
            let boxes = (request.results ?? []).compactMap { observation -> ReceiptParser.TextBox? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let box = observation.boundingBox
                return ReceiptParser.TextBox(text: candidate.string, minX: box.minX, midY: 1 - box.midY, height: box.height)
            }
            return ReceiptParser.rows(boxes).joined(separator: "\n")
        }.value
    }

    // MARK: - Stored copy

    static func storedJPEG(_ image: UIImage) -> Data? {
        let size = image.size
        let short = min(size.width, size.height) * image.scale
        guard short > storedShortSide else { return image.jpegData(compressionQuality: jpegQuality) }
        let factor = storedShortSide / short
        let target = CGSize(width: (size.width * image.scale * factor).rounded(), height: (size.height * image.scale * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: jpegQuality)
    }

    private static func render(_ image: UIImage) -> UIImage {
        UIGraphicsImageRenderer(size: image.size).image { _ in image.draw(at: .zero) }
    }

    // MARK: - Showing it

    /// A small picture of the receipt for a list row.
    static func thumbnail(kind: Receipt.Kind, data: Data, side: CGFloat = 120) -> UIImage? {
        switch kind {
        case .image:
            return UIImage(data: data)?.preparingThumbnail(of: CGSize(width: side, height: side * 1.4))
        case .pdf:
            return PDFDocument(data: data)?.page(at: 0)?.thumbnail(of: CGSize(width: side, height: side * 1.4), for: .mediaBox)
        }
    }

    /// A file QuickLook can open. The system clears the temporary folder.
    static func previewURL(kind: Receipt.Kind, data: Data, id: UUID) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("receipt-\(id.uuidString)")
            .appendingPathExtension(kind == .pdf ? "pdf" : "jpg")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
