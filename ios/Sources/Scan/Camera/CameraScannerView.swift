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
    /// The torch, on or off. A card slinger is a closed chute, and the light in
    /// it is whatever leaks past the phone.
    var torchOn: Bool = false
    /// How far to zoom in, counted from the scanner's own framing. 1 is that
    /// framing; above it crops further into the sensor.
    var zoom: Double = 1

    static var isSupported: Bool {
        CameraSession.closestFocusingCamera() != nil
    }

    /// Whether this phone's scanning camera has a torch at all, so the caller
    /// can leave the button out rather than offer a control that does nothing.
    static var hasTorch: Bool {
        CameraSession.closestFocusingCamera()?.hasTorch ?? false
    }

    func makeUIViewController(context: Context) -> CameraScannerController {
        let controller = CameraScannerController()
        controller.onObservation = onObservation
        controller.mode = mode
        controller.torchOn = torchOn
        controller.zoom = zoom
        return controller
    }

    func updateUIViewController(_ controller: CameraScannerController, context: Context) {
        controller.onObservation = onObservation
        controller.mode = mode
        controller.torchOn = torchOn
        controller.zoom = zoom

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

    /// Set from SwiftUI on every update, so each only reaches the lens when it
    /// actually changed. Locking the device for configuration on every pass of
    /// the view body would stall the session for nothing.
    var torchOn = false {
        didSet {
            guard torchOn != oldValue, isRunning else { return }
            camera.setTorch(torchOn)
        }
    }

    var zoom: Double = 1 {
        didSet {
            guard zoom != oldValue, isRunning else { return }
            camera.setZoom(zoom)
        }
    }

    /// True once the session is configured and the lens will take an order.
    private var isRunning = false

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
        // The same rotation the data output applies, stated rather than left to
        // the default. `PreviewGeometry` places the outline on the footing that
        // the preview shows the very buffer Vision read, and that holds only
        // while the two connections agree.
        if let connection = layer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
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
        isRunning = true
        // Whatever he chose before the camera was ready. The setters above are
        // no-ops until now, so the first application happens here.
        camera.setZoom(zoom)
        camera.setTorch(torchOn)
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
        // A stopped session leaves the torch burning, and the screen it returns
        // to has no control to put it out.
        if !running { camera.setTorch(false) }
        running ? camera.start() : camera.stop()
        if running, isRunning { camera.setTorch(torchOn) }
    }

    deinit {
        focusTimer?.invalidate()
    }

    // MARK: - Frames in

    private func received(_ reading: FrameReader.Reading) {
        draw(reading.cardCorners, frameSize: reading.frameSize)

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

    private func draw(_ corners: [CGPoint]?, frameSize: CGSize) {
        guard let corners, corners.count == 4, let preview else {
            outline.path = nil
            return
        }
        let path = UIBezierPath()
        for (index, corner) in corners.enumerated() {
            guard let point = PreviewGeometry.previewPoint(
                forVision: corner,
                frameSize: frameSize,
                bounds: preview.bounds
            ) else {
                outline.path = nil
                return
            }
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

/// Where a point in the camera frame lands in the preview.
///
/// The outline was drawn through `layerPointConverted(fromCaptureDevicePoint:)`,
/// which reads its argument in the capture device's own space: normalised over
/// the sensor, in the sensor's landscape orientation. Vision's corners are not
/// in that space. They are normalised over the buffer the data output hands us,
/// and that buffer has already been rotated upright. Feeding the one to the
/// other drew an outline that sat off the card and had the wrong shape, so the
/// green quad he aims with described nothing he was looking at.
///
/// The preview shows exactly that same rotated buffer, scaled to fill the view
/// and cropped where the two shapes disagree. That is a mapping we can write
/// down, so it is written down here, where a test can hold it to it.
enum PreviewGeometry {
    /// `point` is normalised over the frame with the origin at the bottom left,
    /// which is how Vision reports. The result is in the layer's coordinates,
    /// with the origin at the top left, which is how Core Animation draws.
    ///
    /// `.resizeAspectFill`: the frame is scaled by whichever of the two ratios
    /// is larger, so it covers the view, and it overhangs on the other axis by
    /// equal amounts at each end.
    static func previewPoint(
        forVision point: CGPoint,
        frameSize: CGSize,
        bounds: CGRect
    ) -> CGPoint? {
        guard frameSize.width > 0, frameSize.height > 0,
              bounds.width > 0, bounds.height > 0
        else { return nil }

        let scale = max(bounds.width / frameSize.width, bounds.height / frameSize.height)
        let shown = CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
        let origin = CGPoint(
            x: bounds.midX - shown.width / 2,
            y: bounds.midY - shown.height / 2
        )
        return CGPoint(
            x: origin.x + point.x * shown.width,
            // Vision counts up from the bottom; the layer counts down from the
            // top.
            y: origin.y + (1 - point.y) * shown.height
        )
    }
}
