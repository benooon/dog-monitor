import DogMonitorCore
import Foundation
import Observation

/// Viewer side of the realtime channel: live camera presence for the home screen, and
/// `watch`/`unwatch` so cameras know someone is looking (they only stream then).
@MainActor
@Observable
final class ViewerRealtime {
    /// Presence reported by the server; cameras missing here fall back to their last heartbeat.
    private(set) var presence: [UUID: Bool] = [:]
    /// The dog's state per camera, as last reported.
    private(set) var dogStates: [UUID: DogState] = [:]
    private(set) var isConnected = false

    private let connection: RealtimeConnection
    @ObservationIgnored private var watching: Set<UUID> = []
    @ObservationIgnored private var listener: Task<Void, Never>?

    init(api: DogMonitorAPI) {
        let request = api.realtimeRequest()
        connection = RealtimeConnection { request }
    }

    func start() {
        guard listener == nil else { return }
        let events = connection.events()
        connection.start()
        listener = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connection.stop()
        isConnected = false
    }

    func watch(_ cameraId: UUID) {
        watching.insert(cameraId)
        let connection = connection
        Task { await connection.send(.watch(cameraId: cameraId)) }
    }

    func unwatch(_ cameraId: UUID) {
        guard watching.remove(cameraId) != nil else { return }
        let connection = connection
        Task { await connection.send(.unwatch(cameraId: cameraId)) }
    }

    private func handle(_ event: RealtimeConnection.Event) {
        switch event {
        case .connected:
            isConnected = true
            // The server forgets watches when the socket drops; re-announce them.
            let connection = connection
            for cameraId in watching {
                Task { await connection.send(.watch(cameraId: cameraId)) }
            }
        case .disconnected:
            isConnected = false
        case .message(.cameras(let cameras)):
            presence = Dictionary(cameras.map { ($0.id, $0.online) }, uniquingKeysWith: { _, new in new })
            dogStates = Dictionary(
                cameras.compactMap { camera in camera.dogState.map { (camera.id, $0) } },
                uniquingKeysWith: { _, new in new }
            )
        case .message(.cameraState(let cameraId, let state)):
            dogStates[cameraId] = state
        case .message(.presence(let cameraId, let online)):
            presence[cameraId] = online
        case .message:
            break
        }
    }
}
