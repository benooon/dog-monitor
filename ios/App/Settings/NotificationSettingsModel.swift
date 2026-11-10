import DogMonitorCore
import Foundation
import Observation

/// Loads, edits and saves the viewer's push settings (`GET` / `PUT /notification-prefs`).
@MainActor
@Observable
final class NotificationSettingsModel {
    enum Phase: Equatable {
        case loading, ready, failed
    }

    private(set) var phase: Phase = .loading
    var settings = NotificationSettings(NotificationPrefsDTO(types: [], prefs: []))
    private(set) var isSaving = false
    /// Set when saving fails; drives an alert.
    var saveFailed = false
    let cameras: [DeviceDTO]

    private let api: DogMonitorAPI
    /// The rows as last loaded or saved, to tell whether anything changed.
    private var savedRows: [NotificationPrefDTO] = []

    init(api: DogMonitorAPI, cameras: [DeviceDTO], loaded: NotificationPrefsDTO? = nil) {
        self.api = api
        self.cameras = cameras
        if let loaded { apply(loaded) }
    }

    var hasChanges: Bool {
        phase == .ready && settings.requestPrefs() != savedRows
    }

    func overriddenTypes(for camera: DeviceDTO) -> [EventType] {
        settings.overriddenTypes(camera: camera.id)
    }

    func load() async {
        phase = .loading
        do {
            apply(try await api.notificationPrefs())
        } catch {
            phase = .failed
        }
    }

    /// Saves every change; returns whether it worked.
    func save() async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            apply(try await api.replaceNotificationPrefs(settings.requestPrefs()))
            return true
        } catch {
            saveFailed = true
            return false
        }
    }

    private func apply(_ dto: NotificationPrefsDTO) {
        var loaded = NotificationSettings(dto)
        loaded.keepOverrides(forCameras: Set(cameras.map(\.id)))
        settings = loaded
        savedRows = loaded.requestPrefs()
        phase = .ready
    }
}
