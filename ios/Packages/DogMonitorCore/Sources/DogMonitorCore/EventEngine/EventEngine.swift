import Foundation

/// What the engine reports. `started` and `escalated` usually mean a push; the rest update the timeline.
public enum EngineOutput: Sendable, Equatable {
    /// A new event (push-worthy). For `calmedDown` the event is already ended.
    case started(DogEvent)
    /// A cooled-down episode continued the previous event; no new push.
    case resumed(DogEvent)
    /// The event is still going after `duration` seconds.
    case escalated(DogEvent, duration: TimeInterval)
    /// The event finished; `endedAt` is set.
    case ended(DogEvent)

    public var event: DogEvent {
        switch self {
        case .started(let event), .resumed(let event), .ended(let event): event
        case .escalated(let event, _): event
        }
    }
}

/// Turns raw detections and classifier states into events (SPEC §5). Pure and clock-free:
/// time comes only from detection timestamps and `tick(now:)`, so tests replay timelines exactly.
public struct EventEngine: Sendable {
    public let cameraID: UUID
    public let configuration: EventEngineConfiguration
    private let makeID: @Sendable () -> UUID

    private var barking: EventChannel
    private var whining: EventChannel
    private var visual: [DogState: EventChannel]
    private var lastObservedState: DogState = .unknown
    private var lastObservationAt: Date?

    /// An alert (barking/whining) happened and "calmed down" has not been sent yet.
    private var calmArmed = false

    public init(
        cameraID: UUID,
        configuration: EventEngineConfiguration = .default,
        makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.cameraID = cameraID
        self.configuration = configuration
        self.makeID = makeID
        barking = EventChannel(config: configuration.barking)
        whining = EventChannel(config: configuration.whining)
        visual = [
            .atDoor: EventChannel(config: configuration.atDoor),
            .forbiddenZone: EventChannel(config: configuration.forbiddenZone),
            .notVisible: EventChannel(config: configuration.notVisible),
        ]
    }

    /// The dog's state right now: audio alerts win over the visual classifier's state.
    public func currentState(at now: Date) -> DogState {
        if barking.isActive(at: now) { return .barking }
        if whining.isActive(at: now) { return .whining }
        return lastObservedState
    }

    public var activeEvents: [DogEvent] {
        ([barking.activeEvent, whining.activeEvent] + visual.values.map(\.activeEvent)).compactMap { $0 }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Feeds an audio detection. Detections below the confidence threshold are ignored.
    public mutating func ingest(_ detection: Detection) -> [EngineOutput] {
        var outputs = tick(now: detection.timestamp)
        guard detection.kind.isAudio, detection.meets(threshold: configuration.audioConfidenceThreshold) else {
            return outputs
        }
        switch detection.kind {
        case .bark, .growl:
            barking.hit(at: detection.timestamp, confidence: detection.confidence)
        case .whimper, .howl:
            whining.hit(at: detection.timestamp, confidence: detection.confidence)
        default:
            return outputs
        }
        outputs += tick(now: detection.timestamp)
        return outputs
    }

    /// Feeds the visual classifier's state (called at its analysis rate, e.g. 1–3 Hz).
    public mutating func observe(_ state: DogState, at time: Date) -> [EngineOutput] {
        var outputs = tick(now: time)
        lastObservedState = state
        lastObservationAt = time
        if visual[state] != nil {
            visual[state]!.hit(at: time, confidence: 1)
            outputs += tick(now: time)
        }
        return outputs
    }

    /// Advances time: ends finished episodes, sends escalations and "calmed down". Call periodically (e.g. every second).
    public mutating func tick(now: Date) -> [EngineOutput] {
        var outputs: [EngineOutput] = []
        let calmNotSent = calmArmed
        outputs += barking.evaluate(now: now, cameraID: cameraID, mayResume: calmNotSent, makeID: makeID)
        outputs += whining.evaluate(now: now, cameraID: cameraID, mayResume: calmNotSent, makeID: makeID)
        for state in [DogState.atDoor, .forbiddenZone, .notVisible] {
            outputs += visual[state]!.evaluate(now: now, cameraID: cameraID, mayResume: true, makeID: makeID)
        }

        if outputs.contains(where: { output in
            if case .started(let event) = output { return event.type == .prolongedBarking || event.type == .whining }
            return false
        }) {
            calmArmed = true
        }
        outputs += checkCalm(now: now)
        return outputs
    }

    private mutating func checkCalm(now: Date) -> [EngineOutput] {
        guard calmArmed else { return [] }
        if barking.isActive(at: now) || whining.isActive(at: now) { return [] }
        let quietSince = [barking.lastSeen, whining.lastSeen].compactMap { $0 }.max()
        guard let quietSince, now.timeIntervalSince(quietSince) >= configuration.calmAfter else { return [] }
        // "Calmed down" means quiet *and* resting when the camera can see the dog (SPEC §5).
        if let lastObservationAt, now.timeIntervalSince(lastObservationAt) <= configuration.visualFreshness,
           lastObservedState != .resting {
            return []
        }
        calmArmed = false
        let event = DogEvent(
            id: makeID(),
            cameraID: cameraID,
            type: .calmedDown,
            startedAt: now,
            endedAt: now,
            confidence: 1
        )
        return [.started(event)]
    }
}
