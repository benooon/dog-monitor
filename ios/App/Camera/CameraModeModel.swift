import AVFoundation
import CoreImage
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

    /// Something moved in the last few seconds; heavier video analysis runs only while true.
    private(set) var isMotionActive = false
    /// The latest Vision result: where the dog is and its posture (empty when no dog was seen).
    private(set) var dogDetections: [Detection] = []
    /// Door / forbidden / bed zones drawn in setup (cached on the phone, synced when paired).
    private(set) var zones: [CameraZone] = CameraModeModel.cachedZones()
    /// Heat and power problems to show on the camera screen, most important first.
    private(set) var healthWarnings: [CameraHealth.Warning] = []

    let capture: CaptureService
    private var healthReporter: HealthReporter?
    private var healthMonitor: HealthMonitor?
    private var appliedFrameRate: Int?
    /// Live view (realtime link + LiveKit), only when this phone is paired as a camera.
    private(set) var live: CameraLiveController?
    private var credential: APICredential

    private var meterTask: Task<Void, Never>?
    private var motionTask: Task<Void, Never>?
    private var motionResultsTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var detectionTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var recorderTask: Task<Void, Never>?
    /// Ring-buffer clip recorder; runs only when paired (clips are for upload).
    private(set) var recorder: ClipRecorder?
    private var engine: EventEngine?
    /// Visual state from motion, dog position and posture (SPEC §4 layer 3), fed to the engine.
    private var classifier = DogStateClassifier()
    /// Today's (and recent days') rest, barks and activity, persisted and uploaded when paired.
    private var summaries = CameraModeModel.loadSummaries()
    private let uploader = EventUploader(store: FileEventQueueStore(url: CameraModeModel.queueURL))
    private let mediaUploader = MediaUploader(
        directory: CameraModeModel.mediaDirectory,
        store: FileEventQueueStore(url: CameraModeModel.mediaQueueURL)
    )
    private var mediaTask: Task<Void, Never>?
    /// Keeps clips for the daily highlight reel and uploads it once a day is final (Premium).
    private let reelBuilder = HighlightReelBuilder()
    /// Started dog events, until their clip is saved and handed to the reel builder.
    private var reelEvents: [UUID: HighlightReelBuilder.EventInfo] = [:]
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
            startMotionDetection()
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
        for task in [meterTask, analysisTask, detectionTask, tickTask, motionTask, motionResultsTask] { task?.cancel() }
        motionTask = nil
        motionResultsTask = nil
        isMotionActive = false
        dogDetections = []
        meterTask = nil
        analysisTask = nil
        detectionTask = nil
        tickTask = nil
        // Lets the publisher drain what is already queued, then end.
        outputContinuation?.finish()
        outputContinuation = nil
        engine = nil
        saveSummaries()
        healthMonitor = nil
        healthWarnings = []
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

    /// Frame differencing at ~4 fps off the main actor, gating Vision dog detection (twice a
    /// second while something moves, every 10 s otherwise).
    private func startMotionDetection() {
        motionTask?.cancel()
        motionResultsTask?.cancel()
        let samples = capture.samples(.video, bufferingNewest: 1)
        let (results, continuation) = AsyncStream<VideoAnalysis>.makeStream(bufferingPolicy: .bufferingNewest(4))
        motionTask = Task.detached(priority: .utility) {
            var detector = MotionDetector()
            var lastVision: Date?
            for await sample in samples where sample.kind == .video {
                let now = Date.now
                guard detector.wants(now), let frame = MotionAnalyzer.lumaFrame(from: sample, timestamp: now) else { continue }
                let result = detector.process(frame)
                let gateOpen = detector.isActive(at: now)
                var dog: [Detection]?
                if DogVisionAnalyzer.isDue(lastRun: lastVision, now: now, motion: gateOpen) {
                    lastVision = now
                    dog = DogVisionAnalyzer.analyze(sample, at: now)
                }
                continuation.yield(VideoAnalysis(motion: result, gateOpen: gateOpen, dog: dog))
            }
            continuation.finish()
        }
        motionResultsTask = Task { [weak self] in
            for await analysis in results {
                self?.videoAnalyzed(analysis)
            }
        }
    }

    private func videoAnalyzed(_ analysis: VideoAnalysis) {
        if analysis.gateOpen, !isMotionActive, let detection = MotionDetector.detection(for: analysis.motion) {
            detectionLog.append(detection)
        }
        if analysis.gateOpen != isMotionActive { isMotionActive = analysis.gateOpen }
        classifier.noteMotion(analysis.motion.hasMotion, at: analysis.motion.timestamp)
        if let dog = analysis.dog {
            observe(classifier.classify(dog, at: analysis.motion.timestamp), at: analysis.motion.timestamp)
            // Log only changes (dog appears, posture changes), not every look.
            if dog.map(\.kind) != dogDetections.map(\.kind) {
                dog.forEach { detectionLog.append($0) }
            }
            dogDetections = dog
        }
    }

    // MARK: - Daily summary

    nonisolated private static var summaryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("daily-summary.json")
    }

    nonisolated private static func loadSummaries() -> DailySummaryAccumulator {
        guard let data = try? Data(contentsOf: summaryURL),
              let saved = try? JSONDecoder().decode(DailySummaryAccumulator.self, from: data)
        else { return DailySummaryAccumulator() }
        return saved
    }

    private func saveSummaries() {
        guard let data = try? JSONEncoder().encode(summaries) else { return }
        try? FileManager.default.createDirectory(at: Self.summaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.summaryURL, options: .atomic)
    }

    private func tickSummary(save: Bool, upload: Bool) {
        summaries.tick(state: dogState, moving: isMotionActive, at: .now, calendar: .current)
        if save { saveSummaries() }
        if upload { Task { await uploadSummaries() } }
    }

    /// Sends finished days (which triggers the daily summary push) and today so far.
    private func uploadSummaries() async {
        guard let api else { return }
        for pending in summaries.pendingUploads(now: .now, calendar: .current) {
            do {
                if pending.final {
                    // Store the day, then try its reel before sending the day as final, so the
                    // summary push can say the reel is ready. A reel that fails now is retried
                    // later; the push doesn't wait for it.
                    try await api.uploadSummary(pending.summary, final: false)
                    await reelBuilder.dayFinished(pending.summary.date)
                    await reelBuilder.uploadPending(using: api, calendar: .current)
                }
                try await api.uploadSummary(pending.summary, final: pending.final)
                if pending.final {
                    summaries.markUploadedFinal(pending.summary.date)
                }
            } catch {
                return // offline: try again at the next upload
            }
        }
        saveSummaries()
        await reelBuilder.uploadPending(using: api, calendar: .current)
    }

    // MARK: - Zones

    nonisolated static let zonesKey = "camera.zones"

    nonisolated static func cachedZones(defaults: UserDefaults = .standard) -> [CameraZone] {
        guard let data = defaults.data(forKey: zonesKey) else { return [] }
        return (try? JSONDecoder().decode([CameraZone].self, from: data)) ?? []
    }

    private func applyZones(_ zones: [CameraZone]) {
        self.zones = zones
        classifier.zones = DogZones(zones)
        if let data = try? JSONEncoder().encode(zones) {
            UserDefaults.standard.set(data, forKey: Self.zonesKey)
        }
    }

    /// Picks up zones saved from another install of this camera; keeps the cache when offline.
    private func refreshZones() async {
        guard let api, let remote = try? await api.zones() else { return }
        applyZones(remote)
    }

    /// Saves zones on the phone and, when paired, to the backend. Returns false if the upload
    /// failed (the zones still apply on this phone).
    func saveZones(_ zones: [CameraZone]) async -> Bool {
        let valid = zones.filter(\.polygon.isValid)
        applyZones(valid)
        guard let api else { return true }
        do {
            applyZones(try await api.replaceZones(valid))
            return true
        } catch {
            return false
        }
    }

    /// The next camera frame as an image, for drawing zones on. Nil when the camera isn't running.
    func snapshot() async -> CGImage? {
        guard status == .running else { return nil }
        let samples = capture.samples(.video, bufferingNewest: 1)
        let frame = await Task.detached(priority: .userInitiated) { () -> ImageBox? in
            for await sample in samples where sample.kind == .video {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample.buffer) else { continue }
                let image = CIImage(cvPixelBuffer: pixelBuffer)
                return CIContext().createCGImage(image, from: image.extent).map(ImageBox.init)
            }
            return nil
        }.value
        return frame?.image
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
        classifier = DogStateClassifier(zones: DogZones(zones))
        Task { await refreshZones() }
        Task { await uploadSummaries() }
        healthMonitor = HealthMonitor(cameraID: cameraID)
        if healthReporter == nil { healthReporter = HealthReporter() }
        appliedFrameRate = nil
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
                self.tickSummary(save: ticks % 60 == 0, upload: ticks % 900 == 0)
                if ticks % 5 == 1 { self.checkHealth() }
            }
        }
        flushEvents()
    }

    private func ingest(_ detection: Detection) {
        if detection.kind == .bark, detection.meets(threshold: Detection.defaultAudioConfidenceThreshold) {
            summaries.noteBark(at: detection.timestamp, calendar: .current)
        }
        guard var engine else { return }
        let outputs = engine.ingest(detection)
        self.engine = engine
        dogState = engine.currentState(at: .now)
        record(outputs)
    }

    private func observe(_ state: DogState, at time: Date) {
        guard var engine else { return }
        let outputs = engine.observe(state, at: time)
        self.engine = engine
        dogState = engine.currentState(at: time)
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

    /// Reads battery, charging and heat: updates the on-screen warnings, slows capture when the
    /// phone is hot, and reports long unplugs and overheating to viewers as events.
    private func checkHealth() {
        guard var monitor = healthMonitor, let reporter = healthReporter else { return }
        let outputs = monitor.update(reporter.current())
        healthMonitor = monitor
        if healthWarnings != monitor.screenWarnings { healthWarnings = monitor.screenWarnings }
        let fps = monitor.targetFrameRate
        if fps != appliedFrameRate {
            capture.setFrameRate(fps)
            appliedFrameRate = fps
        }
        record(outputs)
    }

    private func record(_ outputs: [EngineOutput]) {
        guard !outputs.isEmpty, isPaired else { return }
        if let recorder {
            // Clips are for dog events; health events (battery, heat) have nothing to film.
            for case .started(let event) in outputs where event.type.dogState != nil && event.type != .calmedDown {
                recorder.trigger(eventID: event.id)
                inlineSnapshots.insert(event.id)
                if reelEvents.count > 100 { reelEvents.removeAll() }
                reelEvents[event.id] = HighlightReelBuilder.EventInfo(
                    type: event.type,
                    place: ReelCandidate.place(for: event.type, zones: zones),
                    startedAt: event.startedAt,
                    confidence: event.confidence
                )
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
        // Copy the clip for the reel before the uploader can delete it.
        if kind == .clip, let info = reelEvents.removeValue(forKey: item.eventID) {
            await reelBuilder.keep(clipAt: item.url, eventID: item.eventID, info: info)
        }
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

/// One analyzed frame: motion, and Vision's dog detections when it ran on this frame.
private struct VideoAnalysis: Sendable {
    var motion: MotionResult
    var gateOpen: Bool
    var dog: [Detection]?
}

/// Hands a freshly made frame image from the conversion task to the main actor.
private struct ImageBox: @unchecked Sendable {
    let image: CGImage
}
