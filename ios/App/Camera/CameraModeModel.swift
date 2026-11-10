import AVFoundation
import DogMonitorCore
import Foundation
import Observation

/// Drives camera mode: permissions, the capture session, and the black/preview screen.
@MainActor
@Observable
final class CameraModeModel {
    enum Status: Equatable {
        case idle
        case starting
        case running
        case denied
        case failed
    }

    private(set) var status: Status = .idle
    /// False when microphone access was denied: video still works, bark detection does not.
    private(set) var hasAudio = false
    /// Debug readout of the frames the app actually receives.
    private(set) var videoFPS: Double = 0
    private(set) var screen = CameraScreenState()
    /// Recent audio detections, for the debug overlay.
    private(set) var detectionLog = DetectionLog()

    let capture: CaptureService

    private var meterTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var detectionTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var savedBrightness: Double?
    private var isSceneActive = true

    init(capture: CaptureService = CaptureService()) {
        self.capture = capture
    }

    /// Barks in the last minute, for the debug overlay.
    var recentBarkCount: Int {
        detectionLog.count(of: .bark, within: 60, before: .now)
    }

    var isPreviewVisible: Bool {
        status == .running && screen.isPreviewVisible(at: .now)
    }

    func start() async {
        switch status {
        case .starting, .running: return
        case .idle, .denied, .failed: break
        }
        status = .starting
        guard await CaptureService.requestAccess(for: .video) else {
            status = .denied
            return
        }
        hasAudio = await CaptureService.requestAccess(for: .audio)
        do {
            try await capture.start(includeAudio: hasAudio)
            // Stopped (or the screen left) while the session was starting.
            guard status == .starting else {
                capture.stop()
                return
            }
            status = .running
            screen.hidePreview()
            startFrameMeter()
            if hasAudio { startAudioAnalysis() }
            applyDisplay()
        } catch {
            if status == .starting { status = .failed }
        }
    }

    func stop() {
        guard status == .running || status == .starting else { return }
        for task in [meterTask, analysisTask, detectionTask] { task?.cancel() }
        meterTask = nil
        analysisTask = nil
        detectionTask = nil
        hideTask?.cancel()
        capture.stop()
        status = .idle
        videoFPS = 0
        screen.hidePreview()
        applyDisplay()
    }

    /// Tap anywhere: show the preview, or hide it if it is showing.
    func tap() {
        guard status == .running else { return }
        screen.tap(at: .now)
        scheduleAutoHide()
        applyDisplay()
    }

    func scenePhaseChanged(isActive: Bool) {
        isSceneActive = isActive
        applyDisplay()
    }

    // MARK: - Private

    private func startFrameMeter() {
        meterTask?.cancel()
        let samples = capture.samples(.video, bufferingNewest: 1)
        meterTask = Task { [weak self] in
            var meter = FrameRateMeter()
            var lastPublished = -Double.infinity
            for await sample in samples where sample.kind == .video {
                let time = sample.presentationTime
                meter.record(time)
                if time - lastPublished >= 1 {
                    lastPublished = time
                    self?.videoFPS = meter.framesPerSecond
                }
            }
        }
    }

    private func startAudioAnalysis() {
        // A fresh detector per run, so a run still winding down never shares state with a new one.
        let detector = BarkDetector()
        // Audio buffers are small and the classifier needs a continuous signal, so buffer deeper.
        let samples = capture.samples(.audio, bufferingNewest: 64)
        let detections = detector.detections()
        analysisTask = Task.detached(priority: .userInitiated) {
            await detector.run(samples: samples)
        }
        detectionTask = Task { [weak self] in
            for await detection in detections {
                self?.detectionLog.append(detection)
            }
        }
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        guard let deadline = screen.previewVisibleUntil else { return }
        hideTask = Task { [weak self] in
            let delay = max(deadline.timeIntervalSinceNow, 0)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            if !self.screen.isPreviewVisible(at: .now) {
                self.screen.hidePreview()
                self.applyDisplay()
            }
        }
    }

    /// Black + dim + no auto-lock while running in the foreground; the user's settings otherwise.
    private func applyDisplay() {
        let takeOver = status == .running && isSceneActive
        DisplayControl.setIdleTimerDisabled(takeOver)
        if takeOver, let target = screen.screenBrightness(at: .now) {
            if savedBrightness == nil { savedBrightness = DisplayControl.brightness }
            DisplayControl.setBrightness(target)
        } else if let saved = savedBrightness {
            DisplayControl.setBrightness(saved)
            savedBrightness = nil
        }
    }
}
