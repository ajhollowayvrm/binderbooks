import SwiftUI

#if os(iOS)
import VisionKit

/// VisionKit's live text and barcode scanner, wrapped for SwiftUI.
///
/// The loop never blocks. Every frame's items go through `FrameInterpreter`
/// and `DuplicateGate`: a card is accepted once per visit, and a visit ends
/// only after its number has been out of the frame for a moment. "Same card
/// again" covers deliberate duplicates.
/// How the loop logs cards.
enum ScanMode: String, CaseIterable {
    /// Every card that passes through the frame logs on its own. For a stack
    /// or a card slinger.
    case automatic
    /// Nothing logs until the shutter is tapped. For a binder page, where
    /// nine cards sit in view at once.
    case manual

    var title: String {
        switch self {
        case .automatic: return "Auto"
        case .manual: return "Manual"
        }
    }
}

struct ScannerView: UIViewControllerRepresentable {
    var isActive: Bool
    var mode: ScanMode
    /// Increment to capture the current frame in manual mode.
    var captureCount: Int
    var onObservation: (ScanObservation) -> Void
    /// Manual mode, shutter tapped, nothing readable in view.
    var onNothingToCapture: () -> Void = {}

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
        context.coordinator.mode = mode
        if captureCount != context.coordinator.handledCaptureCount {
            context.coordinator.handledCaptureCount = captureCount
            if !context.coordinator.captureNow() {
                onNothingToCapture()
            }
        }
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

        var mode: ScanMode = .automatic
        var handledCaptureCount = 0

        /// Barcodes already turned into a slab. Cleared when the item leaves.
        private var consumedBarcodes: Set<UUID> = []
        private var gate = DuplicateGate()
        /// What the last frame read. Manual mode captures this on demand.
        private var latest: ScanObservation = ScanObservation()

        /// Manual mode: log the card in view. False when no number was read.
        func captureNow() -> Bool {
            guard latest.number != nil || latest.name != nil else { return false }
            onObservation(latest)
            return true
        }

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
                consumedBarcodes.remove(item.id)
            }
            process(allItems, in: dataScanner)
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

            let (observation, _) = FrameInterpreter.interpret(texts)
            latest = observation
            switch mode {
            case .automatic:
                if gate.shouldAccept(observation.number) {
                    onObservation(observation)
                }
            case .manual:
                // Keep the gate's clock honest so a switch back to automatic
                // does not re-log the card already in view.
                _ = gate.shouldAccept(observation.number)
            }
        }
    }
}
#endif
