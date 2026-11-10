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

    private let api: DogMonitorAPI
    private let capture: CaptureService
    private let connection: RealtimeConnection
    private let publisher = LivePublisher()
    private let health = HealthReporter()
    private let logger = Logger(subsystem: "com.benooon.dogmonitor", category: "CameraLive")
    @ObservationIgnored private var policy = PublishPolicy()
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var lingerTask: Task<Void, Never>?
    @ObservationIgnored private var isReconciling = false
    @ObservationIgnored private var needsReconcile = false

    init(api: DogMonitorAPI, capture: CaptureService) {
        self.api = api
        self.capture = capture
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
        link = .offline
        let publisher = publisher
        Task { await publisher.stop() }
    }

    // MARK: - Private

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

    private func sendHeartbeat() async {
        await connection.send(.heartbeat(health.current()))
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
            if !isStreaming || !publisher.isConnected {
                do {
                    let token = try await api.deviceLiveToken()
                    try await publisher.start(token: token, frames: capture.samples(.video, bufferingNewest: 1))
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
