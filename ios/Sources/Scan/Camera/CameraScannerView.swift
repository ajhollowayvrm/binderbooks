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
    /// The frame is full of something the rectangle detector cannot call a
    /// card. He is almost always too close: a card whose edges leave the frame
    /// has no quadrilateral, and nothing is read from a frame with no card.
    var onCardNotFramed: () -> Void = {}
    /// The camera cannot run, or can again. Nil clears the fault.
    var onFault: (ScannerFault?) -> Void = { _ in }
    /// What the loop is doing, reported every frame.
    var onState: (ScanState) -> Void = { _ in }
    /// The torch, on or off. A card slinger is a closed chute, and the light in
    /// it is whatever leaks past the phone.
    var torchOn: Bool = false
    /// How far to zoom in, counted from the scanner's own framing. 1 is that
    /// framing; above it crops further into the sensor.
    var zoom: Double = 1
    /// The catalogue he is scanning. Vision reads that language and no other.
    var language: ScanLanguage = .english

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
        controller.onCardNotFramed = onCardNotFramed
        controller.onFault = onFault
        controller.onState = onState
        controller.mode = mode
        controller.torchOn = torchOn
        controller.zoom = zoom
        controller.language = language
        return controller
    }

    func updateUIViewController(_ controller: CameraScannerController, context: Context) {
        controller.onObservation = onObservation
        controller.onCardNotFramed = onCardNotFramed
        controller.onFault = onFault
        controller.onState = onState
        controller.mode = mode
        controller.torchOn = torchOn
        controller.zoom = zoom
        controller.language = language

        if captureCount != controller.handledCaptureCount {
            controller.handledCaptureCount = captureCount
            onCaptureBegan()
            let ended = onCaptureEnded
            let nothing = onNothingToCapture
            let withoutNumber = onCapturedWithoutNumber
            controller.captureNow { outcome in
                ended(false)
                switch outcome {
                case .nothing: nothing()
                case .withoutNumber: withoutNumber()
                case .complete: break
                }
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
    var onCardNotFramed: (() -> Void)?
    /// Raised when the camera cannot run, and cleared with nil once it does.
    var onFault: ((ScannerFault?) -> Void)?
    /// What the loop is doing, every frame. The status bar shows it, so a
    /// scanner that is refusing cards no longer looks like an empty chute.
    var onState: ((ScanState) -> Void)?
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
    /// Where the card has to sit. Drawn always, because the one framing fault
    /// that costs him a card is invisible otherwise: too close reads nothing
    /// and looks exactly like an empty chute.
    private let guideBox = CAShapeLayer()

    /// When the frame last held detail and no card. Held so the hint waits for
    /// the fault to persist rather than firing on the frame he is mid-swap on.
    private var unreadSince: Date?
    private var lastHintAt: Date?

    /// Reading state. Touched only on the frame queue, except where noted.
    private let state = ReadingState()

    /// Set from SwiftUI. The reader holds it behind the same lock the frames
    /// go through, because he can change it while the camera is running.
    var language: ScanLanguage = .english {
        didSet {
            guard language != oldValue else { return }
            state.language = language
        }
    }

    private var pipeline = ScanPipeline()
    /// The last state published, so an unchanged one is not published again.
    private var lastState: ScanState?
    /// When a frame last arrived. Nil until the session delivers its first.
    private var lastFrameAt: Date?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        outline.fillColor = UIColor.clear.cgColor
        outline.strokeColor = UIColor.systemGreen.withAlphaComponent(0.9).cgColor
        outline.lineWidth = 3
        outline.lineJoin = .round

        guideBox.fillColor = UIColor.clear.cgColor
        guideBox.strokeColor = UIColor.white.withAlphaComponent(0.35).cgColor
        guideBox.lineWidth = 2
        guideBox.lineDashPattern = [10, 8]

        Task { await start() }
    }

    private func start() async {
        // Both of these used to be a bare `return`. A denied permission and a
        // session that would not configure each left a black rectangle and no
        // word about why, which is indistinguishable from a scanner that is
        // working and sees nothing.
        guard await CameraSession.authorize() else {
            onFault?(.permissionDenied)
            return
        }
        do {
            try camera.configure()
            camera.capExposure()
        } catch {
            onFault?(.configurationFailed(error.localizedDescription))
            return
        }
        onFault?(nil)

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
        layer.addSublayer(guideBox)
        layer.addSublayer(outline)
        preview = layer
        layoutGuide()

        let state = self.state
        camera.setFrameHandler { [weak self] pixels, _ in
            guard let self else { return }
            // The shutter takes the next frame whole, before the live loop
            // sees it.
            if state.takeCaptureRequest() {
                let forced = state.readForced(pixels)
                Task { @MainActor in
                    self.finishCapture(forced)
                }
                return
            }
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
                self.checkFrames()
            }
        }
    }

    /// How long the session may deliver no frames at all before saying so.
    ///
    /// Thirty a second is the normal rate, so three seconds of silence is not a
    /// slow moment, it is a stopped session. Long enough that a hitch while the
    /// app returns to the foreground does not raise it.
    private static let frameSilence: TimeInterval = 3

    /// Everything else in this controller reports what the frames *said*. This
    /// reports that no frame said anything, which is the one failure the rest
    /// of the loop cannot see: an `AVCaptureSession` that starts and then stops
    /// delivering looks exactly like a lens pointed at an empty chute, because
    /// in both cases the last thing anyone heard was "nothing there".
    private func checkFrames() {
        guard isRunning, let last = lastFrameAt else { return }
        guard Date().timeIntervalSince(last) >= Self.frameSilence else { return }
        report(.stalled)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        layoutGuide()
    }

    /// The card has to fit, whole, inside the frame Vision reads. The preview
    /// is `.resizeAspectFill` and therefore shows *less* than the buffer holds,
    /// so a card inside this box is inside the buffer with room to spare.
    private func layoutGuide() {
        guard let preview else { return }
        let bounds = preview.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let aspect = CGFloat(CardRectifier.cardAspect)
        var height = bounds.height * 0.78
        var width = height * aspect
        let widest = bounds.width * 0.86
        if width > widest {
            width = widest
            height = width / aspect
        }
        let box = CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
        guideBox.path = UIBezierPath(roundedRect: box, cornerRadius: width * 0.05).cgPath
    }

    /// How long the frame must stay full and unreadable before he is told, and
    /// how long before he is told again. Long enough that turning a card over
    /// never trips it.
    private static let framingHintDelay: TimeInterval = 1.2
    private static let framingHintRepeat: TimeInterval = 4

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
        noteFraming(reading)

        let now = Date()
        lastFrameAt = now

        // A slab is its own thing: read once per visit, by barcode.
        if let cert = reading.observation.certNumber {
            if pipeline.gate.shouldAccept(cert: cert, at: now) {
                onObservation?(reading.observation)
            }
            return
        }

        state.accumulate(reading.observation)
        var merged = state.merged()
        // One frame that found a card is enough to say a card is there. The
        // merged window can lag a frame behind on this.
        merged.sawCard = merged.sawCard || reading.observation.sawCard

        // Every frame reaches the pipeline, including the frames that read no
        // word off the card and the frames that arrive in manual mode. That is
        // how it knows the card is still there: a number is unreadable far more
        // often than a card is absent, and treating an unreadable number as
        // "the card left" logged the card twice.
        switch pipeline.consider(merged, mode: mode, at: now) {
        case .queue(let observation):
            onObservation?(observation)
            state.resetAccumulator(afterLogging: observation)
            report(.idle)
        case .waiting(let waiting):
            report(waiting)
        }
    }

    /// Publish the loop's state, and only when it changes.
    ///
    /// Frames arrive thirty times a second. Assigning SwiftUI state on each of
    /// them re-evaluates the scan screen thirty times a second — including the
    /// strip of squares — to say the same thing it said last frame.
    private func report(_ next: ScanState) {
        guard next != lastState else { return }
        lastState = next
        onState?(next)
    }

    /// A frame full of detail with no card in it. Nothing is read from such a
    /// frame, and the usual cause is that he is too close for the card's edges
    /// to fit. Tell him, rather than leaving a scanner that silently does
    /// nothing.
    private func noteFraming(_ reading: FrameReader.Reading) {
        let now = Date()
        guard reading.sharpness > 0 else { return }
        guard state.policy.looksFilledButUnread(sawCard: reading.observation.sawCard, sharpness: reading.sharpness) else {
            unreadSince = nil
            return
        }
        let since = unreadSince ?? now
        unreadSince = since
        guard now.timeIntervalSince(since) >= Self.framingHintDelay else { return }
        if let last = lastHintAt, now.timeIntervalSince(last) < Self.framingHintRepeat { return }
        lastHintAt = now
        onCardNotFramed?()
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

    private var captureCompletion: ((CaptureOutcome) -> Void)?

    /// The shutter. It always tries.
    ///
    /// It used to send whatever the live window held, and send nothing unless
    /// that window had found a card outline and read a word. A card held in a
    /// sleeve, or held still for less than a second, gave a window with an
    /// attack name in it and no number, and "Shield Press" was logged for a
    /// Zamazenta whose number was sharp on screen. Now the next frame is read
    /// with every gate off (`FrameReader.readForced`), and the window fills in
    /// only what that frame could not read.
    func captureNow(completion: @escaping (CaptureOutcome) -> Void) {
        // A second press while the first is reading waits for the first.
        guard captureCompletion == nil else { return }
        captureCompletion = completion
        state.requestCapture()
        // A session that stopped delivering frames never answers. Give up
        // rather than leave the shutter spinning.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.captureCompletion != nil else { return }
            self.state.cancelCaptureRequest()
            self.finishCapture(ScanObservation())
        }
    }

    private func finishCapture(_ forced: ScanObservation) {
        guard let completion = captureCompletion else { return }
        captureCompletion = nil

        var observation = forced
        let window = state.merged()
        if observation.number == nil, observation.certNumber == nil, let number = window.number {
            observation.number = number
        }
        if observation.nameCandidates.isEmpty {
            observation.nameCandidates = window.nameCandidates
            observation.name = window.name
        }
        if observation.artDescriptor == nil, let art = window.artDescriptor {
            observation.artDescriptor = art
            observation.artSharpness = window.artSharpness
            observation.artIsBestEffort = window.artIsBestEffort
        }

        guard !observation.isEmpty || observation.artDescriptor != nil else {
            completion(.nothing)
            return
        }
        onObservation?(observation)
        // The pipeline has to know, or switching back to automatic with the
        // same card still in the chute logs it a second time.
        pipeline.noteCaptured(observation)
        state.resetAccumulator(afterLogging: observation)
        completion(observation.number == nil && observation.certNumber == nil ? .withoutNumber : .complete)
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
    private var captureRequested = false

    /// The shutter asks for the next frame.
    func requestCapture() {
        lock.lock(); captureRequested = true; lock.unlock()
    }

    func cancelCaptureRequest() {
        lock.lock(); captureRequested = false; lock.unlock()
    }

    /// True once per request, on the frame that answers it.
    func takeCaptureRequest() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let requested = captureRequested
        captureRequested = false
        return requested
    }

    func readForced(_ pixels: CVPixelBuffer) -> ScanObservation {
        lock.lock(); defer { lock.unlock() }
        return reader.readForced(pixels)
    }

    var isFocusing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isFocusing }
        set { lock.lock(); _isFocusing = newValue; lock.unlock() }
    }

    /// The cadences and the thresholds the reader works to. Read only.
    var policy: FramePolicy {
        lock.lock(); defer { lock.unlock() }; return reader.policy
    }

    /// Which language Vision reads. Changing it throws the window away: the
    /// readings in it were read under the other alphabet.
    var language: ScanLanguage {
        get { lock.lock(); defer { lock.unlock() }; return reader.language }
        set {
            lock.lock()
            reader.language = newValue
            accumulator.reset()
            bestSharpness = 0
            lock.unlock()
        }
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

    /// The same, and the card just logged stays out of the next window.
    func resetAccumulator(afterLogging card: ScanObservation) {
        lock.lock()
        accumulator.reset(afterLogging: card)
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
