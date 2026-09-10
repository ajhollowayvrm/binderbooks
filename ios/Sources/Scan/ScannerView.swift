import SwiftUI

#if os(iOS)
import VisionKit

/// VisionKit's live text and barcode scanner, wrapped for SwiftUI.
///
/// The loop never blocks. Every frame's items go through `FrameInterpreter`;
/// a card is accepted once per visit to the frame. The number item must leave
/// the frame before the same card can be logged again, which is more reliable
/// than a time-based cooldown. `onSameCardAgain` covers deliberate duplicates.
struct ScannerView: UIViewControllerRepresentable {
    var isActive: Bool
    var onObservation: (ScanObservation) -> Void

    static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [
                .text(languages: ["en", "ja"]),
                .barcode(symbologies: [.qr, .code128, .code39, .pdf417, .dataMatrix]),
            ],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        context.coordinator.scanner = scanner
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onObservation = onObservation
        if isActive, !scanner.isScanning {
            try? scanner.startScanning()
        } else if !isActive, scanner.isScanning {
            scanner.stopScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onObservation: onObservation)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onObservation: (ScanObservation) -> Void
        weak var scanner: DataScannerViewController?

        /// Number items already turned into a card. Cleared when the item leaves.
        private var consumedNumberItems: Set<UUID> = []
        /// Barcodes already turned into a slab. Cleared when the item leaves.
        private var consumedBarcodes: Set<UUID> = []
        /// The number text seen on the previous callback, so one flicker does not log a card.
        private var lastNumber: (id: UUID, value: String)?

        init(onObservation: @escaping (ScanObservation) -> Void) {
            self.onObservation = onObservation
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            process(allItems, in: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            process(allItems, in: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didRemove removedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in removedItems {
                consumedNumberItems.remove(item.id)
                consumedBarcodes.remove(item.id)
                if lastNumber?.id == item.id { lastNumber = nil }
            }
        }

        private func process(_ items: [RecognizedItem], in scanner: DataScannerViewController) {
            let viewHeight = max(scanner.view.bounds.height, 1)
            var texts: [RecognizedText] = []
            for item in items {
                switch item {
                case .text(let text):
                    let top = text.bounds.topLeft.y / viewHeight
                    let height = (text.bounds.bottomLeft.y - text.bounds.topLeft.y) / viewHeight
                    texts.append(RecognizedText(id: item.id, transcript: text.transcript, top: top, height: height))
                case .barcode(let barcode):
                    guard !consumedBarcodes.contains(item.id), let payload = barcode.payloadStringValue,
                          let cert = FrameInterpreter.cert(fromBarcode: payload) else { continue }
                    consumedBarcodes.insert(item.id)
                    onObservation(ScanObservation(certNumber: cert.cert, grader: cert.grader))
                @unknown default:
                    continue
                }
            }

            let (observation, numberID) = FrameInterpreter.interpret(texts)
            guard let numberID, let number = observation.number, !consumedNumberItems.contains(numberID) else { return }

            // Require the same reading twice before logging. OCR flickers.
            if let last = lastNumber, last.id == numberID, last.value == number {
                consumedNumberItems.insert(numberID)
                lastNumber = nil
                onObservation(observation)
            } else {
                lastNumber = (numberID, number)
            }
        }
    }
}
#endif
