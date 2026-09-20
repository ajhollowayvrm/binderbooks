import AVFoundation
import CoreVideo
import Foundation

/// The camera, owned outright.
///
/// `DataScannerViewController` gave text and a `capturePhoto()` that tears down
/// the preview, and nothing in between: no frames. Artwork matching needs a
/// picture of every card, not of the rare one whose text failed, so the session
/// is ours now. What that buys, beyond the artwork itself:
///
/// - the sharpest frame of the last second, instead of whichever arrived,
/// - one Vision pipeline over one buffer, rather than text and pixels read from
///   two different captures of two different moments,
/// - the focus, the exposure and the lens left under our control.
///
/// Everything here is Apple's and free: AVFoundation for the frames, Vision for
/// the reading, Accelerate for the focus score.
@MainActor
final class CameraSession: NSObject {
    /// Called on the frame queue, not the main actor, for every frame.
    ///
    /// Held behind a lock rather than on the main actor: the delegate fires on
    /// a background queue thirty times a second, and hopping to the main actor
    /// to read a closure would both stall the queue and be a lie about where
    /// this runs.
    func setFrameHandler(_ handler: ((CVPixelBuffer, CMTime) -> Void)?) {
        sink.setHandler(handler)
    }

    private let sink = FrameSink()
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.ajholloway.binderbooks.frames", qos: .userInitiated)
    private var device: AVCaptureDevice?
    private var isConfigured = false

    enum Failure: LocalizedError {
        case noCamera
        case cannotAddInput
        case cannotAddOutput

        var errorDescription: String? {
            switch self {
            case .noCamera: return "This device has no camera the scanner can use."
            case .cannotAddInput: return "The camera could not be attached to the session."
            case .cannotAddOutput: return "The session would not deliver frames."
            }
        }
    }

    /// The back camera that focuses nearest.
    ///
    /// He identifies a card by holding it close, and the wide camera stops
    /// focusing at about a hand's width. The ultra wide focuses far nearer on
    /// a Pro phone, which is the lens the stock Camera app switches to for
    /// macro. Picking a physical camera rather than a virtual one is on
    /// purpose: a virtual device changes lens mid-session on its own, and a
    /// scanner that reads the same card twice must not read it through two
    /// different lenses.
    ///
    /// Not every phone has an ultra wide that focuses, so the wide camera is
    /// the fallback and the behaviour there is unchanged.
    static func closestFocusingCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )
        let cameras = discovery.devices
        let ultraWide = cameras.first { $0.deviceType == .builtInUltraWideCamera }
        // An ultra wide with no autofocus focuses no nearer than the wide one,
        // and it is the softer sensor. It is only worth taking when it focuses.
        if let ultraWide, ultraWide.isFocusModeSupported(.continuousAutoFocus) {
            return ultraWide
        }
        return cameras.first { $0.deviceType == .builtInWideAngleCamera }
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    // MARK: - Setting up

    func configure() throws {
        guard !isConfigured else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // 1080p. The collector number is the smallest print on a card and the
        // reason the old still path existed; 720p loses it at arm's length.
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high

        guard let camera = Self.closestFocusingCamera() else {
            throw Failure.noCamera
        }
        device = camera

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw Failure.cannotAddInput }
        session.addInput(input)

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        // A late frame is a stale frame. The card has moved on.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(sink, queue: queue)
        guard session.canAddOutput(output) else { throw Failure.cannotAddOutput }
        session.addOutput(output)

        if let connection = output.connection(with: .video) {
            // The card is held upright and the reading assumes it.
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }

        configureLens(camera)
        isConfigured = true
    }

    /// Close focus, continuous, and steady exposure.
    ///
    /// A card is held close, which is why `closestFocusingCamera` picks the
    /// lens it does. Left alone the lens still hunts for the desk behind the
    /// card, and every frame in between is soft.
    private func configureLens(_ camera: AVCaptureDevice) {
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }

            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            // Tell the lens the subject is near. Without this it racks past the
            // card to the room behind it.
            if camera.isAutoFocusRangeRestrictionSupported {
                camera.autoFocusRangeRestriction = .near
            }
            if camera.isFocusPointOfInterestSupported {
                camera.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                camera.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            matchWideFieldOfView(camera)

            // Foil throws hard highlights. Letting the exposure sit a little
            // under keeps the pattern visible instead of blown white.
            if camera.isExposureModeSupported(.continuousAutoExposure),
               camera.minExposureTargetBias <= -0.3 {
                camera.setExposureTargetBias(-0.3)
            }
        } catch {
            // An unconfigurable lens still takes pictures. Carry on.
        }
    }

    /// The longest the shutter may stay open for one frame.
    ///
    /// Continuous auto exposure in a room chooses about 1/30 s, and a card held
    /// in a hand moves during that time: every frame smears, the number reads
    /// wrong or not at all, and no frame is sharp enough to sign. At 1/100 s
    /// the lens raises the ISO instead. Grain costs Vision far less than blur.
    static let longestExposure = CMTime(value: 1, timescale: 100)

    /// Cap the exposure time. Called after the session commits its
    /// configuration, because committing a preset resets the cap to the
    /// format's default.
    func capExposure() {
        guard let device, device.isExposureModeSupported(.continuousAutoExposure) else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let format = device.activeFormat
            var cap = Self.longestExposure
            if CMTimeCompare(cap, format.minExposureDuration) < 0 { cap = format.minExposureDuration }
            if CMTimeCompare(cap, format.maxExposureDuration) > 0 { cap = format.maxExposureDuration }
            device.activeMaxExposureDuration = cap
        } catch {
            // The lens keeps its own exposure. Carry on.
        }
    }

    /// Crop the ultra wide back to the wide camera's field of view.
    ///
    /// The ultra wide sees about twice as much of the room, so a card held at
    /// one distance lands on about half as many pixels across. The collector
    /// number is the smallest print on a card, and it does not survive that
    /// loss: the name still reads, the number stops reading, and a card with a
    /// name and no number is matched on the name alone.
    ///
    /// Zoom is a sensor crop, so this costs no detail. It buys back the
    /// framing the wide camera gave while keeping the close focus that is the
    /// reason for taking the ultra wide at all.
    ///
    /// Call this with the device already locked for configuration.
    private func matchWideFieldOfView(_ camera: AVCaptureDevice) {
        guard camera.deviceType == .builtInUltraWideCamera else { return }
        let wide = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        ).devices.first
        guard let wide else { return }

        let ultraAngle = Double(camera.activeFormat.videoFieldOfView)
        let wideAngle = Double(wide.activeFormat.videoFieldOfView)
        guard wideAngle > 0, ultraAngle > wideAngle else { return }

        // Field of view is an angle across the frame; zoom is a ratio of
        // widths. Half-angle tangents convert the one to the other.
        let factor = tan(ultraAngle / 2 * .pi / 180) / tan(wideAngle / 2 * .pi / 180)
        baseZoom = min(max(1, factor), Double(camera.maxAvailableVideoZoomFactor))
        camera.videoZoomFactor = CGFloat(baseZoom)
    }

    /// The zoom the lens sits at before he asks for any. On the ultra wide this
    /// is the crop back to the wide camera's field of view, and on the wide
    /// camera it is 1. Everything he chooses multiplies this, so asking for 1
    /// gives the framing the scanner was built around rather than undoing the
    /// crop.
    private(set) var baseZoom: Double = 1

    /// True while the lens is moving, so the frame is not worth signing.
    var isFocusing: Bool {
        device?.isAdjustingFocus ?? false
    }

    // MARK: - Running

    func start() {
        guard !session.isRunning else { return }
        let session = session
        Task.detached(priority: .userInitiated) {
            session.startRunning()
        }
    }

    func stop() {
        guard session.isRunning else { return }
        let session = session
        Task.detached(priority: .userInitiated) {
            session.stopRunning()
        }
    }

    // MARK: - Permission

    static func authorize() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    // MARK: - Zoom and light

    /// Zoom, counted from the scanner's own framing rather than from the lens.
    ///
    /// 1 is the framing `matchWideFieldOfView` sets, and 2 is twice into it.
    /// Counting from the lens instead would make 1 mean "undo the crop", which
    /// is the one setting no card scan wants.
    func setZoom(_ relative: Double) {
        guard let device else { return }
        let wanted = baseZoom * max(0.1, relative)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.videoZoomFactor = max(
                device.minAvailableVideoZoomFactor,
                min(CGFloat(wanted), device.maxAvailableVideoZoomFactor)
            )
        } catch {}
    }

    func setTorch(_ on: Bool) {
        guard let device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.torchMode = on ? .on : .off
        } catch {}
    }
}

/// Receives frames on the capture queue and hands them on.
///
/// Its own object, so the delegate callback never has to reach into a
/// main-actor type from a background queue.
private final class FrameSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((CVPixelBuffer, CMTime) -> Void)?

    func setHandler(_ handler: ((CVPixelBuffer, CMTime) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        let handler = handler
        lock.unlock()
        handler?(pixels, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}
