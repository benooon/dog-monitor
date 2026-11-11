import DogMonitorCore
import Foundation
import Observation
import os

/// Camera side of live view: keeps the realtime connection, sends heartbeats, and publishes to
/// LiveKit only while viewers watch (plus a short linger), per SPEC §3.
@MainActor
@Observable
final class CameraLiveController {
    enum Link: Equatable {
        case connecting
        case online
        case offline
    }

    static let heartbeatInterval: Duration = .seconds(45)

    private(set) var link: Link = .connecting
    private(set) var viewerCount = 0
    private(set) var isStreaming = false
    /// A viewer is talking through the camera's speaker right now (privacy: always shown).
    private(set) var isViewerTalking = false
    /// The household's live video is end-to-end encrypted but this phone has no key, so it
    /// never publishes (clear video would break the household's privacy). Fixed by scanning
    /// an invite QR code from the owner's phone.
    private(set) var needsLiveKey = CameraLiveController.rememberedNeedsLiveKey

    /// Remembered so the camera's start screen can say live view is off before it connects.
    nonisolated static let needsLiveKeyDefaultsKey = "camera.liveNeedsKey"
    nonisolated static var rememberedNeedsLiveKey: Bool {
        UserDefaults.standard.bool(forKey: needsLiveKeyDefaultsKey)
    }

    private func setNeedsLiveKey(_ needsKey: Bool) {
        guard needsLiveKey != needsKey else { return }
        needsLiveKey = needsKey
        UserDefaults.standard.set(needsKey, forKey: Self.needsLiveKeyDefaultsKey)
        // Viewers learn right away that live view is off here (or back on).
        Task { await sendHeartbeat() }
    }

    private let api: DogMonitorAPI
    private let capture: CaptureService
    private let liveKeys = LiveKeyStore(store: KeychainStore())
    private let connection: RealtimeConnection
    private let publisher = LivePublisher()
    private let health = HealthReporter()
    private let logger = Logger(subsystem: "com.benooon.dogmonitor", category: "CameraLive")
    @ObservationIgnored private var policy = PublishPolicy()
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var lingerTask: Task<Void, Never>?
    @ObservationIgnored private var isReconciling = false
    @ObservationIgnored private var needsReconcile = false

    /// The dog's current state, sent with every heartbeat.
    private let dogState: @MainActor () -> DogState

    init(api: DogMonitorAPI, capture: CaptureService, dogState: @escaping @MainActor () -> DogState = { .unknown }) {
        self.api = api
        self.capture = capture
        self.dogState = dogState
        let request = api.realtimeRequest()
        connection = RealtimeConnection { request }
    }

    func start() {
        guard tasks.isEmpty else { return }
        let events = connection.events()
        connection.start()
        tasks.append(Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let talking = self.isStreaming && self.publisher.isViewerTalking
                if talking != self.isViewerTalking { self.isViewerTalking = talking }
                try? await Task.sleep(for: .milliseconds(500))
            }
        })
        tasks.append(Task { [weak self] in
            await self?.checkLiveKey()
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.sendHeartbeat()
                try? await Task.sleep(for: Self.heartbeatInterval)
            }
        })
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        lingerTask?.cancel()
        connection.stop()
        policy.connectionLost(at: .now)
        viewerCount = 0
        isStreaming = false
        isViewerTalking = false
        link = .offline
        let publisher = publisher
        Task { await publisher.stop() }
    }

    /// A key was scanned: check again and publish if viewers are waiting.
    func liveKeyChanged() {
        Task {
            await checkLiveKey()
            await reconcile()
        }
    }

    // MARK: - Private

    /// A camera without the key learns right away whether it may publish, so its screen can
    /// say so before anyone tries to watch.
    private func checkLiveKey() async {
        guard liveKeys.load() == nil else {
            setNeedsLiveKey(false)
            return
        }
        guard let token = try? await api.deviceLiveToken() else { return }
        setNeedsLiveKey(LiveEncryption.mode(key: nil, householdEncrypted: token.isHouseholdEncrypted) == .needsKey)
    }

    private func handle(_ event: RealtimeConnection.Event) {
        switch event {
        case .connected:
            link = .online
            Task { await sendHeartbeat() }
        case .disconnected:
            link = .offline
            policy.connectionLost(at: .now)
            viewerCount = 0
        case .message(.viewers(let count, _)):
            viewerCount = count
            policy.viewersChanged(to: count, at: .now)
        case .message(.error(let code)):
            logger.error("Realtime error: \(code, privacy: .public)")
        case .message:
            break
        }
        Task { await reconcile() }
    }

    /// Call when the dog's state changes so viewers see it without waiting for the next heartbeat.
    func dogStateChanged() {
        Task { await sendHeartbeat() }
    }

    private func sendHeartbeat() async {
        let state = dogState()
        await connection.send(.heartbeat(
            health.current(),
            dogState: state == .unknown ? nil : state,
            liveKeyMissing: needsLiveKey
        ))
    }

    /// Starts or stops publishing to match the policy, and schedules the linger stop.
    /// Calls during a reconcile (which awaits the network) are coalesced into one more pass.
    private func reconcile() async {
        needsReconcile = true
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }
        while needsReconcile {
            needsReconcile = false
            await reconcileOnce()
        }
    }

    private func reconcileOnce() async {
        let now = Date.now
        if policy.shouldPublish(at: now) {
            let connected = await publisher.isConnected
            if !isStreaming || !connected {
                do {
                    let token = try await api.deviceLiveToken()
                    let key: LiveKey?
                    switch LiveEncryption.mode(key: liveKeys.load(), householdEncrypted: token.isHouseholdEncrypted) {
                    case .encrypted(let liveKey):
                        key = liveKey
                        setNeedsLiveKey(false)
                    case .clear:
                        key = nil
                        setNeedsLiveKey(false)
                    case .needsKey:
                        setNeedsLiveKey(true)
                        isStreaming = false
                        return
                    }
                    try await publisher.start(
                        token: token,
                        key: key,
                        frames: capture.samples(.video, bufferingNewest: 1),
                        // ~20 ms per buffer: keep a few hundred ms so audio is not dropped.
                        audio: capture.samples(.audio, bufferingNewest: 16)
                    )
                    isStreaming = true
                } catch {
                    logger.error("Could not start publishing: \(String(describing: error), privacy: .public)")
                    isStreaming = false
                }
            }
        } else if isStreaming {
            await publisher.stop()
            isStreaming = false
        }

        lingerTask?.cancel()
        if let deadline = policy.stopDeadline(after: .now) {
            lingerTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(deadline.timeIntervalSinceNow, 0) + 0.1))
                guard !Task.isCancelled else { return }
                await self?.reconcile()
            }
        }
    }
}
