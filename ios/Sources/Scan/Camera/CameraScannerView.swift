import AVFoundation
import CoreVideo
import SwiftUI
import UIKit

/// The viewfinder, on a camera session we own.
///
/// Same interface the old `ScannerView` presented, so the session screen did
/// not have to change. What is different is underneath: every frame is ours, so
/// the card is outlined as he aims, the sharpest look at it is the one that
/// gets signed, and a capture no longer tears the preview down.
struct CameraScannerView: UIViewControllerRepresentable {
    var isActive: Bool
    var mode: ScanMode
    var captureCount: Int
    var onObservation: (ScanObservation) -> Void
    var onNothingToCapture: () -> Void = {}
    var onCaptureBegan: () -> Void = {}
    /// Kept for the call site. Nothing tears the preview down any more, so the
    /// flag it passes is always false.
    var onCaptureEnded: (Bool) -> Void = { _ in }
    var onCapturedWithoutNumber: () -> Void = {}

    static var isSupported: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    func makeUIViewController(context: Context) -> CameraScannerController {
        let controller = CameraScannerController()
        controller.onObservation = onObservation
        controller.mode = mode
        return controller
    }

    func updateUIViewController(_ controller: CameraScannerController, context: Context) {
        controller.onObservation = onObservation
        controller.mode = mode

        if captureCount != controller.handledCaptureCount {
            controller.handledCaptureCount = captureCount
            onCaptureBegan()
            let outcome = controller.captureNow()
            onCaptureEnded(false)
            switch outcome {
            case .nothing: onNothingToCapture()
            case .withoutNumber: onCapturedWithoutNumber()
            case .complete: break
            }
        }

        controller.setRunning(isActive)
    }

    static func dismantleUIViewController(_ controller: CameraScannerController, coordinator: ()) {
        controller.setRunning(false)
    }
}

/// Holds the session, the preview, and the reading loop.
@MainActor
final class CameraScannerController: UIViewController {
    var onObservation: ((ScanObservation) -> Void)?
    var mode: ScanMode = .automatic
    var handledCaptureCount = 0

    private let camera = CameraSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private let outline = CAShapeLayer()

    /// Reading state. Touched only on the frame queue, except where noted.
    private let state = ReadingState()

    private var gate = DuplicateGate()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        outline.fillColor = UIColor.clear.cgColor
        outline.strokeColor = UIColor.systemGreen.withAlphaComponent(0.9).cgColor
        outline.lineWidth = 3
        outline.lineJoin = .round

        Task { await start() }
    }

    private func start() async {
        guard await CameraSession.authorize() else { return }
        do {
            try camera.configure()
        } catch {
            return
        }

        let layer = AVCaptureVideoPreviewLayer(session: camera.session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        layer.addSublayer(outline)
        preview = layer

        let state = self.state
        camera.setFrameHandler { [weak self] pixels, _ in
            guard let self else { return }
            let focusing = state.isFocusing
            let reading = state.read(pixels, isFocusing: focusing)
            Task { @MainActor in
                self.received(reading)
            }
        }
        camera.start()
        // The lens moving is a main-actor read, so it is sampled here and left
        // where the frame queue can see it.
        startFocusWatch()
    }

    private var focusTimer: Timer?

    private func startFocusWatch() {
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.state.isFocusing = self.camera.isFocusing
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    func setRunning(_ running: Bool) {
        running ? camera.start() : camera.stop()
    }

    deinit {
        focusTimer?.invalidate()
    }

    // MARK: - Frames in

    private func received(_ reading: FrameReader.Reading) {
        draw(reading.cardCorners)

        // A slab is its own thing: read once per visit, by barcode.
        if let cert = reading.observation.certNumber {
            if gate.shouldAccept(cert, at: Date()) {
                onObservation?(reading.observation)
            }
            return
        }

        state.accumulate(reading.observation)

        // Automatic mode logs as soon as a card reads clearly, the way it
        // always has. Manual mode waits for the shutter.
        guard mode == .automatic else { return }
        let merged = state.merged()
        guard let number = merged.number, !merged.isEmpty else { return }
        guard gate.shouldAccept(number, at: Date()) else { return }
        onObservation?(merged)
        state.resetAccumulator()
    }

    private func draw(_ corners: [CGPoint]?) {
        guard let corners, corners.count == 4, let preview else {
            outline.path = nil
            return
        }
        let path = UIBezierPath()
        for (index, corner) in corners.enumerated() {
            // Vision counts from the bottom left; the preview layer converts
            // from its own normalised space with the origin at the top left.
            let point = preview.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: corner.x, y: 1 - corner.y))
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.close()
        outline.path = path.cgPath
    }

    // MARK: - The shutter

    enum CaptureOutcome {
        case nothing, withoutNumber, complete
    }

    func captureNow() -> CaptureOutcome {
        let merged = state.merged()
        guard merged.number != nil || merged.name != nil || merged.certNumber != nil else {
            return .nothing
        }
        onObservation?(merged)
        state.resetAccumulator()
        return merged.number == nil && merged.certNumber == nil ? .withoutNumber : .complete
    }
}

/// The reading state, shared between the frame queue and the main actor.
///
/// Its own object with a lock, because frames arrive on a capture queue and the
/// shutter is pressed on the main one, and both touch the same window of
/// readings.
final class ReadingState: @unchecked Sendable {
    private let lock = NSLock()
    private var reader = FrameReader()
    private var accumulator = ObservationAccumulator()
    private var bestSharpness: Double = 0
    private var _isFocusing = false

    var isFocusing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isFocusing }
        set { lock.lock(); _isFocusing = newValue; lock.unlock() }
    }

    func read(_ pixels: CVPixelBuffer, isFocusing: Bool) -> FrameReader.Reading {
        lock.lock()
        defer { lock.unlock() }
        let reading = reader.read(pixels, at: Date(), bestSharpness: bestSharpness, isFocusing: isFocusing)
        if reading.observation.artDescriptor != nil {
            bestSharpness = max(bestSharpness, reading.sharpness)
        }
        return reading
    }

    func accumulate(_ observation: ScanObservation) {
        lock.lock()
        accumulator.add(observation)
        lock.unlock()
    }

    func merged() -> ScanObservation {
        lock.lock()
        defer { lock.unlock() }
        return accumulator.merged()
    }

    /// After a card is logged, the next one starts from nothing. Its sharpness
    /// ceiling goes with it, or the second card in the stack is never signed.
    func resetAccumulator() {
        lock.lock()
        accumulator.reset()
        bestSharpness = 0
        lock.unlock()
    }
}
