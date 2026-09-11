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

    // MARK: - Setting up

    func configure() throws {
        guard !isConfigured else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // 1080p. The collector number is the smallest print on a card and the
        // reason the old still path existed; 720p loses it at arm's length.
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
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
    /// A card is held about a hand's width away, which is near the close limit
    /// of the wide camera. Left alone the lens hunts for the desk behind it and
    /// every frame in between is soft.
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

    func setZoom(_ factor: Double) {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.videoZoomFactor = max(1, min(factor, device.activeFormat.videoMaxZoomFactor))
        } catch {}
    }

    var hasTorch: Bool { device?.hasTorch ?? false }

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
