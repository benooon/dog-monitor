@preconcurrency import AVFoundation
import DogMonitorCore

/// One sample buffer from the capture session.
///
/// Sample buffers are immutable once delivered, so sharing them across consumers is safe.
/// Consumers must not hold video buffers for long: the capture output has a small buffer
/// pool and stops delivering frames when it runs dry.
struct CaptureSample: @unchecked Sendable {
    enum Kind: Sendable {
        case video
        case audio
    }

    let kind: Kind
    let buffer: CMSampleBuffer

    /// Presentation time in seconds on the capture clock.
    var presentationTime: Double {
        CMSampleBufferGetPresentationTimeStamp(buffer).seconds
    }
}

enum CaptureError: Error, Equatable {
    case noCamera
    case configurationFailed
}

/// Owns the single `AVCaptureSession` (video + audio) of camera mode and fans its sample
/// buffers out to any number of consumers (analysis, recorder, streamer) via `samples(...)`.
/// Video and audio have separate streams so an audio consumer's deeper buffer never holds
/// on to video frames.
///
/// All session work runs on a private serial queue; sample buffers arrive on another one.
final class CaptureService: NSObject, @unchecked Sendable {
    /// Exposed only so a preview layer can attach to it. Do not reconfigure it from outside.
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.benooon.dogmonitor.capture.session")
    private let outputQueue = DispatchQueue(label: "com.benooon.dogmonitor.capture.output", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let videoBroadcaster = Broadcaster<CaptureSample>()
    private let audioBroadcaster = Broadcaster<CaptureSample>()
    // Touched only on `sessionQueue`.
    private var isConfigured = false
    private var runtimeErrorObserver: NSObjectProtocol?
    // Keeps video upright for analysis and streaming as the phone is turned (session queue).
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    override init() {
        super.init()
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.restartAfterRuntimeError()
        }
    }

    deinit {
        if let runtimeErrorObserver {
            NotificationCenter.default.removeObserver(runtimeErrorObserver)
        }
    }

    /// Asks for camera or microphone permission if not decided yet. Returns whether it is granted.
    static func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: mediaType)
        default:
            return false
        }
    }

    /// A stream of every video or audio sample from now on. With a buffer of 1, a slow
    /// consumer just sees the latest sample when it is ready for the next one. Keep video
    /// buffers small (1–2); audio consumers that must not miss samples can use more.
    func samples(_ kind: CaptureSample.Kind, bufferingNewest limit: Int = 1) -> AsyncStream<CaptureSample> {
        switch kind {
        case .video: videoBroadcaster.subscribe(bufferingNewest: limit)
        case .audio: audioBroadcaster.subscribe(bufferingNewest: limit)
        }
    }

    /// Configures the session on first use and starts it.
    /// - Parameter includeAudio: false when microphone permission was denied.
    func start(includeAudio: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            sessionQueue.async { [self] in
                do {
                    if !isConfigured {
                        try configure(includeAudio: includeAudio)
                        isConfigured = true
                    }
                    if !session.isRunning {
                        session.startRunning()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    // MARK: - Private (session queue)

    private func configure(includeAudio: Bool) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // 720p matches the top simulcast layer (SPEC §3) and keeps heat down.
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
        else {
            throw CaptureError.noCamera
        }
        let videoInput = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(videoInput) else { throw CaptureError.configurationFailed }
        session.addInput(videoInput)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(videoOutput) else { throw CaptureError.configurationFailed }
        session.addOutput(videoOutput)
        followDeviceRotation(of: camera)

        // Audio is best effort: without it the camera still streams video, but bark detection is off.
        if includeAudio,
           let microphone = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: microphone),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
            audioOutput.setSampleBufferDelegate(self, queue: outputQueue)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
            }
        }
    }

    private func followDeviceRotation(of camera: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
        rotationCoordinator = coordinator
        applyRotation(coordinator.videoRotationAngleForHorizonLevelCapture)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            self?.sessionQueue.async { self?.applyRotation(angle) }
        }
    }

    private func applyRotation(_ angle: CGFloat) {
        guard let connection = videoOutput.connection(with: .video),
              connection.isVideoRotationAngleSupported(angle)
        else { return }
        connection.videoRotationAngle = angle
    }

    private func restartAfterRuntimeError() {
        sessionQueue.async { [self] in
            guard isConfigured else { return }
            session.startRunning()
        }
    }
}

extension CaptureService: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    // Shared by both delegate protocols; tells video and audio apart by output.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let isVideo = output === videoOutput
        let broadcaster = isVideo ? videoBroadcaster : audioBroadcaster
        guard broadcaster.subscriberCount > 0 else { return }
        broadcaster.yield(CaptureSample(kind: isVideo ? .video : .audio, buffer: sampleBuffer))
    }
}
