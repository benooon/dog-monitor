import ActivityKit
import DogMonitorCore
import Foundation
import Observation

/// Starts and stops camera Live Activities on a viewer's phone and keeps the backend told about
/// their push tokens (`PUT /live-activities`, `DELETE /live-activities/:id`), so it can update them.
@MainActor
@Observable
final class CameraLiveActivityController {
    static let shared = CameraLiveActivityController()

    /// Cameras that have a Live Activity showing right now.
    private(set) var activeCameraIds: Set<UUID> = []

    private var api: DogMonitorAPI?
    /// One token watcher per activity, keyed by `Activity.id`.
    @ObservationIgnored private var watchers: [String: Task<Void, Never>] = [:]
    private let store: LiveActivityRegistrationStore

    init(store: LiveActivityRegistrationStore = LiveActivityRegistrationStore()) {
        self.store = store
    }

    /// Whether the user allows Live Activities for this app.
    var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func isShowing(_ cameraId: UUID) -> Bool {
        activeCameraIds.contains(cameraId)
    }

    /// Picks up activities that outlived the last launch and forgets server records for ones
    /// that ended while the app wasn't running.
    func activate(api: DogMonitorAPI) async {
        self.api = api
        let activities = Activity<CameraActivityAttributes>.activities
        for activity in activities where activity.isRunning {
            watch(activity)
        }
        refreshActive()
        let running = Set(activities.filter(\.isRunning).map(\.id))
        for (activityId, registrationId) in store.all where !running.contains(activityId) {
            await forget(activityId: activityId, registrationId: registrationId)
        }
    }

    func start(camera: DeviceDTO, dogName: String?, content: CameraLiveActivityContent) throws {
        guard !isShowing(camera.id) else { return }
        let attributes = CameraActivityAttributes(cameraId: camera.id, cameraName: camera.name, dogName: dogName)
        let activity = try Activity<CameraActivityAttributes>.request(
            attributes: attributes,
            content: ActivityContent(state: content, staleDate: nil),
            pushType: .token
        )
        activeCameraIds.insert(camera.id)
        watch(activity)
    }

    func stop(cameraId: UUID) async {
        activeCameraIds.remove(cameraId)
        for activity in Activity<CameraActivityAttributes>.activities where activity.attributes.cameraId == cameraId {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Brings showing activities up to date with the realtime channel while the app is open, so
    /// they change at once instead of after the backend's push, and ends the ones whose camera
    /// left the household (unpaired or revoked).
    func sync(dogStates: [UUID: DogState], presence: [UUID: Bool], householdCameras: Set<UUID>?) async {
        let activities = Activity<CameraActivityAttributes>.activities.filter(\.isRunning)
        guard !activities.isEmpty else { return }
        var showing: [UUID: CameraLiveActivityContent] = [:]
        for activity in activities {
            showing[activity.attributes.cameraId] = activity.content.state
        }
        let plan = LiveActivitySync.plan(
            showing: showing,
            dogStates: dogStates,
            presence: presence,
            householdCameras: householdCameras
        )
        guard !plan.isEmpty else { return }
        for cameraId in plan.ends {
            await stop(cameraId: cameraId)
        }
        for activity in activities {
            guard let content = plan.updates[activity.attributes.cameraId] else { continue }
            await activity.update(ActivityContent(state: content, staleDate: nil))
        }
    }

    /// Registers each push token the activity gets. The token sequence finishes when the
    /// activity ends (from the app or swiped away), and then the server record goes too.
    private func watch(_ activity: Activity<CameraActivityAttributes>) {
        let activityId = activity.id
        let cameraId = activity.attributes.cameraId
        guard watchers[activityId] == nil else { return }
        watchers[activityId] = Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                await self?.register(activityId: activityId, cameraId: cameraId, token: token)
            }
            await self?.ended(activityId: activityId)
        }
    }

    private func register(activityId: String, cameraId: UUID, token: Data) async {
        guard let api else { return }
        do {
            let registration = try await api.registerLiveActivity(cameraId: cameraId, pushToken: token)
            store.set(registration.id, for: activityId)
        } catch {
            // The activity still shows its starting state; the next token or launch retries.
        }
    }

    private func ended(activityId: String) async {
        watchers[activityId] = nil
        refreshActive()
        if let registrationId = store.registration(for: activityId) {
            await forget(activityId: activityId, registrationId: registrationId)
        }
    }

    private func forget(activityId: String, registrationId: UUID) async {
        guard let api else { return }
        do {
            try await api.endLiveActivity(id: registrationId)
            store.set(nil, for: activityId)
        } catch let error as APIError where error.code != nil || error.isNotFound {
            store.set(nil, for: activityId)
        } catch {
            // Offline: keep it and try again on the next launch.
        }
    }

    private func refreshActive() {
        activeCameraIds = Set(
            Activity<CameraActivityAttributes>.activities.filter(\.isRunning).map(\.attributes.cameraId)
        )
    }
}

private extension Activity {
    var isRunning: Bool {
        activityState == .active || activityState == .stale
    }
}

private extension APIError {
    var isNotFound: Bool {
        if case .http(404, _) = self { return true }
        return false
    }
}

/// Which server registration belongs to which Live Activity, kept across launches so an
/// activity that ended while the app was closed can be cleaned up later.
struct LiveActivityRegistrationStore {
    private static let key = "liveActivityRegistrations"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var all: [String: UUID] {
        let raw = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        return raw.compactMapValues(UUID.init(uuidString:))
    }

    func registration(for activityId: String) -> UUID? {
        all[activityId]
    }

    func set(_ registrationId: UUID?, for activityId: String) {
        var raw = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        raw[activityId] = registrationId?.uuidString
        defaults.set(raw, forKey: Self.key)
    }
}
