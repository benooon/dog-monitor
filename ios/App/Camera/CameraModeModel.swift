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
    /// The dog's state per the event engine (SPEC §5); viewers see it via heartbeats.
    private(set) var dogState: DogState = .unknown {
        didSet {
            if dogState != oldValue { live?.dogStateChanged() }
        }
    }

    let capture: CaptureService
    /// Live view (realtime link + LiveKit), only when this phone is paired as a camera.
    private(set) var live: CameraLiveController?
    private var credential: APICredential

    private var meterTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var detectionTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var recorderTask: Task<Void, Never>?
    /// Ring-buffer clip recorder; runs only when paired (clips are for upload).
    private(set) var recorder: ClipRecorder?
    private var engine: EventEngine?
    private let uploader = EventUploader(store: FileEventQueueStore(url: CameraModeModel.queueURL))
    private let mediaUploader = MediaUploader(
        directory: CameraModeModel.mediaDirectory,
        store: FileEventQueueStore(url: CameraModeModel.mediaQueueURL)
    )
    private var mediaTask: Task<Void, Never>?
    /// Engine outputs are published one batch at a time, in order (see `publish`).
    private var outputContinuation: AsyncStream<[EngineOutput]>.Continuation?
    /// Started events whose snapshot is uploaded before `POST /events`, so the push has it.
    private var inlineSnapshots: Set<UUID> = []

    nonisolated private static var queueURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("event-queue.json")
    }

    nonisolated private static var mediaQueueURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("media-queue.json")
    }

    nonisolated static var mediaDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("event-media", isDirectory: true)
    }
    private var savedBrightness: Double?
    private var isSceneActive = true

    init(capture: CaptureService = CaptureService(), credential: APICredential? = nil) {
        self.capture = capture
        self.credential = credential ?? CredentialStore(store: KeychainStore()).load()
    }

    /// Paired phones have device credentials; without them the camera only analyzes locally.
    var isPaired: Bool {
        if case .device = credential { return true }
        return false
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
            startEventEngine()
            if hasAudio { startAudioAnalysis() }
            startLive()
            startRecorder()
            applyDisplay()
        } catch {
            if status == .starting { status = .failed }
        }
    }

    func stop() {
        guard status == .running || status == .starting else { return }
        for task in [meterTask, analysisTask, detectionTask, tickTask] { task?.cancel() }
        meterTask = nil
        analysisTask = nil
        detectionTask = nil
        tickTask = nil
        // Lets the publisher drain what is already queued, then end.
        outputContinuation?.finish()
        outputContinuation = nil
        engine = nil
        dogState = .unknown
        hideTask?.cancel()
        live?.stop()
        live = nil
        stopRecorder()
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

    /// Called after `CameraPairingView` stored the new device credential.
    func didPair(with credential: APICredential) {
        self.credential = credential
        if status == .running, live == nil { startLive() }
        if status == .running { startRecorder() }
    }

    private func startRecorder() {
        guard isPaired, recorder == nil else { return }
        let recorder = ClipRecorder(directory: Self.mediaDirectory, includeAudio: hasAudio)
        let video = capture.samples(.video, bufferingNewest: 2)
        let audio = hasAudio ? capture.samples(.audio, bufferingNewest: 32) : nil
        let media = recorder.media()
        self.recorder = recorder
        recorderTask = Task.detached(priority: .userInitiated) {
            await recorder.run(video: video, audio: audio)
        }
        mediaTask = Task { [weak self] in
            for await item in media {
                await self?.recorded(item)
            }
        }
    }

    private func stopRecorder() {
        recorderTask?.cancel()
        recorderTask = nil
        mediaTask?.cancel()
        mediaTask = nil
        recorder?.stop()
        recorder = nil
    }

    private func startLive() {
        guard isPaired else { return }
        let controller = CameraLiveController(
            api: DogMonitorAPI(baseURL: AppConfig.apiBaseURL, credential: credential),
            capture: capture,
            dogState: { [weak self] in self?.dogState ?? .unknown }
        )
        live = controller
        controller.start()
    }

    private var api: DogMonitorAPI? {
        isPaired ? DogMonitorAPI(baseURL: AppConfig.apiBaseURL, credential: credential) : nil
    }

    /// Runs the event engine: detections in, events out, ticking every second for durations,
    /// escalations and "calmed down". Events are queued and uploaded when paired.
    private func startEventEngine() {
        let cameraID: UUID
        if case .device(let id, _) = credential { cameraID = id } else { cameraID = UUID() }
        engine = EventEngine(cameraID: cameraID)
        let (outputs, continuation) = AsyncStream<[EngineOutput]>.makeStream()
        outputContinuation = continuation
        Task { [weak self] in
            for await batch in outputs {
                await self?.publish(batch)
            }
        }
        tickTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                ticks += 1
                self.tick(flush: ticks % 30 == 0)
            }
        }
        flushEvents()
    }

    private func ingest(_ detection: Detection) {
        guard var engine else { return }
        let outputs = engine.ingest(detection)
        self.engine = engine
        dogState = engine.currentState(at: .now)
        record(outputs)
    }

    private func tick(flush: Bool) {
        guard var engine else { return }
        let now = Date.now
        let outputs = engine.tick(now: now)
        self.engine = engine
        dogState = engine.currentState(at: now)
        record(outputs)
        if flush { flushEvents() }
    }

    private func record(_ outputs: [EngineOutput]) {
        guard !outputs.isEmpty, isPaired else { return }
        if let recorder {
            for case .started(let event) in outputs where event.type != .calmedDown {
                recorder.trigger(eventID: event.id)
                inlineSnapshots.insert(event.id)
            }
        }
        outputContinuation?.yield(outputs)
    }

    /// Queues and sends one batch of outputs. Batches run strictly one after another, so a
    /// create is always queued before its updates even while it waits for its snapshot.
    private func publish(_ outputs: [EngineOutput]) async {
        var outputs = outputs
        if let api {
            for index in outputs.indices {
                guard case .started(var event) = outputs[index], inlineSnapshots.contains(event.id) else { continue }
                if let key = await uploadSnapshotInline(eventID: event.id, api: api) {
                    event.snapshotKey = key
                    outputs[index] = .started(event)
                }
            }
        }
        await uploader.enqueue(outputs)
        if let api {
            await uploader.flush(using: api)
            await mediaUploader.flush(using: api)
        }
    }

    /// Waits briefly for the event's snapshot (the next video frame after the trigger) and
    /// uploads it, returning its key. On failure the snapshot goes to the media queue and is
    /// attached later with `PATCH /events/:id`.
    private func uploadSnapshotInline(eventID: UUID, api: DogMonitorAPI) async -> String? {
        defer { inlineSnapshots.remove(eventID) }
        let media = mediaUploader
        let path = media.fileURL(eventID: eventID, kind: .snapshot).path
        var waited = 0
        while !FileManager.default.fileExists(atPath: path), waited < 20 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            return try await media.uploadNow(eventID: eventID, kind: .snapshot, using: api)
        } catch {
            await media.enqueue(eventID: eventID, kind: .snapshot)
            return nil
        }
    }

    /// A clip or snapshot was saved: queue it and try to send it.
    private func recorded(_ item: RecordedMedia) async {
        let kind = item.kind
        // Inline snapshots are handled by `uploadSnapshotInline`.
        if kind == .snapshot, inlineSnapshots.contains(item.eventID) { return }
        await mediaUploader.enqueue(eventID: item.eventID, kind: kind)
        if let api {
            await uploader.flush(using: api)
            await mediaUploader.flush(using: api)
        }
    }

    private func flushEvents() {
        guard let api else { return }
        let uploader = uploader
        let mediaUploader = mediaUploader
        Task {
            await uploader.flush(using: api)
            await mediaUploader.flush(using: api)
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
                self?.ingest(detection)
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
