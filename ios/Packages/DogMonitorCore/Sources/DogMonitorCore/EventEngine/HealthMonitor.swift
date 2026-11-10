import Foundation

/// Thresholds for `HealthMonitor`.
public struct HealthMonitorConfiguration: Sendable, Hashable {
    /// How long the phone may run off the charger before viewers are told (short unplugs are normal).
    public var unpluggedAlertAfter: TimeInterval
    /// How long the phone must stay hot before viewers are told.
    public var overheatingAlertAfter: TimeInterval
    public var normalFrameRate: Int
    /// At `.serious` thermal state (SPEC §6: lower fps as the phone heats up).
    public var hotFrameRate: Int
    /// At `.critical` thermal state.
    public var criticalFrameRate: Int

    public init(
        unpluggedAlertAfter: TimeInterval = 120,
        overheatingAlertAfter: TimeInterval = 30,
        normalFrameRate: Int = 30,
        hotFrameRate: Int = 15,
        criticalFrameRate: Int = 10
    ) {
        self.unpluggedAlertAfter = unpluggedAlertAfter
        self.overheatingAlertAfter = overheatingAlertAfter
        self.normalFrameRate = normalFrameRate
        self.hotFrameRate = hotFrameRate
        self.criticalFrameRate = criticalFrameRate
    }
}

/// Turns the camera phone's health readings into on-screen warnings, a target frame rate, and
/// `lowBattery` / `overheating` events for viewers (SPEC §6). Pure: time comes from `reportedAt`.
///
/// - `lowBattery` ("the camera isn't charging") starts once the phone is off the charger for
///   `unpluggedAlertAfter`, or right away when the battery is below 20 % and not charging.
///   It ends when charging resumes.
/// - `overheating` starts once the thermal state stays `.serious` or worse for
///   `overheatingAlertAfter`, and ends when it drops back to `.fair` or `.nominal`.
/// - Without a battery reading (simulator), power is never reported.
public struct HealthMonitor: Sendable {
    public let cameraID: UUID
    public let configuration: HealthMonitorConfiguration
    public private(set) var latest: CameraHealth?
    private let makeID: @Sendable () -> UUID

    private var unpluggedSince: Date?
    private var hotSince: Date?
    private var powerEvent: DogEvent?
    private var heatEvent: DogEvent?

    public init(
        cameraID: UUID,
        configuration: HealthMonitorConfiguration = HealthMonitorConfiguration(),
        makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.cameraID = cameraID
        self.configuration = configuration
        self.makeID = makeID
    }

    /// Feeds one reading; returns events that started or ended because of it.
    public mutating func update(_ health: CameraHealth) -> [EngineOutput] {
        latest = health
        let now = health.reportedAt
        var outputs: [EngineOutput] = []

        // Power.
        let knowsBattery = health.batteryLevel != nil
        let offCharger = knowsBattery && !health.isCharging
        if offCharger {
            if unpluggedSince == nil { unpluggedSince = now }
        } else {
            unpluggedSince = nil
        }
        let unpluggedTooLong = unpluggedSince.map { now.timeIntervalSince($0) >= configuration.unpluggedAlertAfter } ?? false
        let batteryLow = health.warnings.contains(.lowBattery) && offCharger
        let id = makeID
        let camera = cameraID
        if let output = Self.transition(&powerEvent, type: .lowBattery, active: unpluggedTooLong || batteryLow, ended: !offCharger, now: now, camera: camera, makeID: id) {
            outputs.append(output)
        }

        // Heat.
        let hot = health.thermalState >= .serious
        if hot {
            if hotSince == nil { hotSince = now }
        } else {
            hotSince = nil
        }
        let hotTooLong = hotSince.map { now.timeIntervalSince($0) >= configuration.overheatingAlertAfter } ?? false
        if let output = Self.transition(&heatEvent, type: .overheating, active: hotTooLong, ended: !hot, now: now, camera: camera, makeID: id) {
            outputs.append(output)
        }
        return outputs
    }

    /// Warnings for the camera screen, most important first. Shown right away (no grace period),
    /// so whoever set the phone down sees the problem while still there.
    public var screenWarnings: [CameraHealth.Warning] {
        guard let latest else { return [] }
        var result: [CameraHealth.Warning] = []
        let warnings = latest.warnings
        if warnings.contains(.overheating) { result.append(.overheating) }
        if latest.batteryLevel != nil {
            if warnings.contains(.lowBattery), !latest.isCharging {
                result.append(.lowBattery)
            } else if warnings.contains(.unplugged) {
                result.append(.unplugged)
            }
        }
        return result
    }

    /// Capture frame rate for the current thermal state.
    public var targetFrameRate: Int {
        switch latest?.thermalState ?? .nominal {
        case .nominal, .fair: configuration.normalFrameRate
        case .serious: configuration.hotFrameRate
        case .critical: configuration.criticalFrameRate
        }
    }

    private static func transition(
        _ current: inout DogEvent?,
        type: EventType,
        active: Bool,
        ended: Bool,
        now: Date,
        camera: UUID,
        makeID: @Sendable () -> UUID
    ) -> EngineOutput? {
        if var event = current {
            guard ended else { return nil }
            event.endedAt = now
            current = nil
            return .ended(event)
        }
        guard active else { return nil }
        let event = DogEvent(id: makeID(), cameraID: camera, type: type, startedAt: now, confidence: 1)
        current = event
        return .started(event)
    }
}
