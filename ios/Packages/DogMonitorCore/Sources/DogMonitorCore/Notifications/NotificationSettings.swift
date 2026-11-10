import Foundation

/// Editable push settings for one person, built from `GET /notification-prefs` and turned back
/// into the rows `PUT /notification-prefs` expects.
///
/// - Each event type has a household-wide on/off (`isEnabled(_:)`).
/// - A camera can differ from that (`isEnabled(_:camera:)`); only differences are stored.
/// - One quiet-hours window applies to every type that is not time-sensitive. The backend keeps the
///   window per row, so it is copied onto each row of a type that quiet hours can hold back.
public struct NotificationSettings: Hashable, Sendable {
    /// How the settings screen groups event types.
    public enum Group: String, CaseIterable, Sendable {
        case dog, camera, summary

        public var eventTypes: [EventType] {
            EventType.allCases.filter { NotificationSettings.group(of: $0) == self }
        }
    }

    public var quietHours: QuietHours?
    private var enabled: [EventType: Bool]
    private var overrides: [UUID: [EventType: Bool]]
    private let defaults: [EventType: Bool]
    private let bypass: [EventType: Bool]

    public init(_ dto: NotificationPrefsDTO) {
        var defaults: [EventType: Bool] = [:]
        var bypass: [EventType: Bool] = [:]
        for info in dto.types {
            defaults[info.eventType] = info.enabledByDefault
            bypass[info.eventType] = info.bypassesQuietHours
        }
        self.defaults = defaults
        self.bypass = bypass

        var enabled: [EventType: Bool] = [:]
        var overrides: [UUID: [EventType: Bool]] = [:]
        var quietHours: QuietHours?
        for pref in dto.prefs {
            if let cameraId = pref.cameraId {
                overrides[cameraId, default: [:]][pref.eventType] = pref.enabled
            } else {
                enabled[pref.eventType] = pref.enabled
            }
            if quietHours == nil,
               let start = pref.quietStart.flatMap({ TimeOfDay($0) }),
               let end = pref.quietEnd.flatMap({ TimeOfDay($0) }) {
                quietHours = QuietHours(start: start, end: end)
            }
        }
        self.enabled = enabled
        self.overrides = overrides
        self.quietHours = quietHours
    }

    // MARK: - Reading

    public static func group(of type: EventType) -> Group {
        switch type {
        case .prolongedBarking, .whining, .forbiddenZone, .atDoor, .notVisible, .calmedDown: .dog
        case .cameraOffline, .lowBattery, .overheating: .camera
        case .dailySummary: .summary
        }
    }

    /// Household-wide: whether this type is pushed (the backend default until changed).
    public func isEnabled(_ type: EventType) -> Bool {
        enabled[type] ?? defaults[type] ?? type.isEnabledByDefault
    }

    /// For one camera: its own choice, or the household-wide one.
    public func isEnabled(_ type: EventType, camera: UUID) -> Bool {
        overrides[camera]?[type] ?? isEnabled(type)
    }

    /// Time-sensitive types still come through during quiet hours.
    public func bypassesQuietHours(_ type: EventType) -> Bool {
        bypass[type] ?? (type.interruptionLevel == .timeSensitive)
    }

    /// Types this camera handles differently from the household-wide choice.
    public func overriddenTypes(camera: UUID) -> [EventType] {
        guard let choices = overrides[camera] else { return [] }
        return EventType.allCases.filter { type in
            guard let choice = choices[type] else { return false }
            return choice != isEnabled(type)
        }
    }

    // MARK: - Editing

    public mutating func setEnabled(_ isOn: Bool, for type: EventType) {
        enabled[type] = isOn
    }

    /// Stores a camera's choice only while it differs from the household-wide one.
    public mutating func setEnabled(_ isOn: Bool, for type: EventType, camera: UUID) {
        if isOn == isEnabled(type) {
            overrides[camera]?[type] = nil
            if overrides[camera]?.isEmpty == true { overrides[camera] = nil }
        } else {
            overrides[camera, default: [:]][type] = isOn
        }
    }

    /// Makes the camera follow every household-wide choice again.
    public mutating func resetOverrides(camera: UUID) {
        overrides[camera] = nil
    }

    /// Drops choices for cameras that are no longer in the household.
    public mutating func keepOverrides(forCameras cameras: Set<UUID>) {
        overrides = overrides.filter { cameras.contains($0.key) }
    }

    // MARK: - Saving

    /// The full set of rows for `PUT /notification-prefs`: one household-wide row per type, plus a row
    /// for each camera choice that differs from it. Quiet hours ride on every row they can apply to.
    public func requestPrefs() -> [NotificationPrefDTO] {
        var rows: [NotificationPrefDTO] = []
        for type in EventType.allCases {
            rows.append(row(camera: nil, type: type, enabled: isEnabled(type)))
        }
        for camera in overrides.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            for type in overriddenTypes(camera: camera) {
                rows.append(row(camera: camera, type: type, enabled: isEnabled(type, camera: camera)))
            }
        }
        return rows
    }

    private func row(camera: UUID?, type: EventType, enabled: Bool) -> NotificationPrefDTO {
        let window = bypassesQuietHours(type) ? nil : quietHours
        return NotificationPrefDTO(
            cameraId: camera,
            eventType: type,
            enabled: enabled,
            quietStart: window?.start.wireValue,
            quietEnd: window?.end.wireValue
        )
    }
}
