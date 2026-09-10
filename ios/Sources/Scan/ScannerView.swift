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
    /// The shutter is working. A still and a careful read take a moment, and a
    /// shutter that looks dead gets tapped again.
    var onCaptureBegan: () -> Void = {}
    /// True when a still was taken, so the caller must rebuild the scanner.
    var onCaptureEnded: (Bool) -> Void = { _ in }
    /// Manual mode, a card was logged from its name alone. The number is the
    /// strongest key the scanner has, and a name on its own often cannot say
    /// which printing of a card he is holding.
    var onCapturedWithoutNumber: () -> Void = {}

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
            let coordinator = context.coordinator
            let nothing = onNothingToCapture
            let withoutNumber = onCapturedWithoutNumber
            let ended = onCaptureEnded
            onCaptureBegan()
            Task { @MainActor in
                let (outcome, usedStill) = await coordinator.captureNow()
                ended(usedStill)
                switch outcome {
                case .nothing: nothing()
                case .withoutNumber: withoutNumber()
                case .complete: break
                }
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

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onObservation: (ScanObservation) -> Void
        weak var scanner: DataScannerViewController?

        var mode: ScanMode = .automatic
        var handledCaptureCount = 0

        /// Barcodes already turned into a slab. Cleared when the item leaves.
        private var consumedBarcodes: Set<UUID> = []
        private var gate = DuplicateGate()
        /// What the last frame read. The fallback when nothing accumulated.
        private var latest: ScanObservation = ScanObservation()
        /// What the last second of frames agreed on. This is what the shutter
        /// logs, because one frame is not a reliable read of small print.
        private var accumulator = ObservationAccumulator()

        enum CaptureOutcome {
            /// Nothing readable was in view.
            case nothing
            /// Logged, but from the name alone.
            case withoutNumber
            case complete
        }

        /// Manual mode: log what the last second of frames agreed on.
        ///
        /// This used to photograph the card. A still read it better, but
        /// `capturePhoto()` kills the preview and only a fresh controller
        /// brings it back, so every capture cost a camera warm-up. Merging
        /// frames gets the same resilience for nothing: the number only has to
        /// land in one frame of the window, and one stray reading is outvoted.
        func captureNow() async -> (outcome: CaptureOutcome, usedStill: Bool) {
            var observation = accumulator.merged()
            if observation.isEmpty { observation = latest }

            // The one case worth a still: the frames agreed on nothing at all.
            var usedStill = false
            if observation.isEmpty, let still = await stillObservation() {
                observation = still
                usedStill = true
            }

            guard observation.number != nil || observation.name != nil || observation.certNumber != nil else {
                return (.nothing, usedStill)
            }
            onObservation(observation)
            // The card is logged. Start the next one from a clean slate rather
            // than letting this one's readings vote on it.
            accumulator.reset()
            let outcome: CaptureOutcome = observation.number == nil && observation.certNumber == nil ? .withoutNumber : .complete
            return (outcome, usedStill)
        }

        /// Nil when there is no photo to read, or nothing readable on it.
        private func stillObservation() async -> ScanObservation? {
            guard let scanner else { return nil }
            do {
                let photo = try await scanner.capturePhoto()
                guard let cg = photo.cgImage else { return nil }
                var observation = FrameInterpreter.interpret(try await StillFrameReader.read(cg)).observation

                // The collector number is the smallest print on the card, and
                // the downscale that makes the read fast is what loses it. It
                // is the strongest key the scanner has, so when it is missing
                // the full-resolution photo is worth one more pass.
                if observation.number == nil {
                    let full = FrameInterpreter.interpret(try await StillFrameReader.read(cg, longestSide: nil)).observation
                    if full.number != nil {
                        observation.number = full.number
                        if observation.name == nil { observation.name = full.name }
                    }
                }
                return observation.isEmpty ? nil : observation
            } catch {
                return nil
            }
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
            accumulator.add(observation)
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
