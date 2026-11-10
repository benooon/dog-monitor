import Foundation

/// Rules for one kind of alert episode (SPEC §5).
public struct ChannelConfiguration: Sendable, Equatable {
    public var eventType: EventType
    /// Sustained activity needed before an event fires.
    public var minDuration: TimeInterval
    /// Alternatively: this many hits within `countWindow` also fires (nil = duration only).
    public var countThreshold: Int?
    public var countWindow: TimeInterval
    /// A gap longer than this ends the episode.
    public var gapTolerance: TimeInterval
    /// A new episode within this time after the last event ended continues that event (no new push).
    public var cooldown: TimeInterval
    /// Event durations at which an escalation update is sent ("barking for 5 minutes").
    public var escalations: [TimeInterval]

    public init(
        eventType: EventType,
        minDuration: TimeInterval,
        countThreshold: Int? = nil,
        countWindow: TimeInterval = 60,
        gapTolerance: TimeInterval,
        cooldown: TimeInterval = 5 * 60,
        escalations: [TimeInterval] = []
    ) {
        self.eventType = eventType
        self.minDuration = minDuration
        self.countThreshold = countThreshold
        self.countWindow = countWindow
        self.gapTolerance = gapTolerance
        self.cooldown = cooldown
        self.escalations = escalations.sorted()
    }
}

public struct EventEngineConfiguration: Sendable, Equatable {
    public var barking: ChannelConfiguration
    public var whining: ChannelConfiguration
    public var atDoor: ChannelConfiguration
    public var forbiddenZone: ChannelConfiguration
    public var notVisible: ChannelConfiguration
    /// Minimum confidence for audio detections.
    public var audioConfidenceThreshold: Double
    /// Quiet time after a barking/whining event before "calmed down" fires.
    public var calmAfter: TimeInterval

    public init(
        barking: ChannelConfiguration,
        whining: ChannelConfiguration,
        atDoor: ChannelConfiguration,
        forbiddenZone: ChannelConfiguration,
        notVisible: ChannelConfiguration,
        audioConfidenceThreshold: Double = Detection.defaultAudioConfidenceThreshold,
        calmAfter: TimeInterval = 2 * 60
    ) {
        self.barking = barking
        self.whining = whining
        self.atDoor = atDoor
        self.forbiddenZone = forbiddenZone
        self.notVisible = notVisible
        self.audioConfidenceThreshold = audioConfidenceThreshold
        self.calmAfter = calmAfter
    }

    public static let `default` = EventEngineConfiguration(
        barking: ChannelConfiguration(
            eventType: .prolongedBarking, minDuration: 10, countThreshold: 6, gapTolerance: 8,
            escalations: [5 * 60.0, 15 * 60.0, 30 * 60.0]
        ),
        whining: ChannelConfiguration(
            eventType: .whining, minDuration: 15, countThreshold: 5, gapTolerance: 8,
            escalations: [5 * 60.0, 15 * 60.0]
        ),
        atDoor: ChannelConfiguration(eventType: .atDoor, minDuration: 30, gapTolerance: 10, escalations: [10 * 60.0]),
        forbiddenZone: ChannelConfiguration(eventType: .forbiddenZone, minDuration: 5, gapTolerance: 10),
        notVisible: ChannelConfiguration(eventType: .notVisible, minDuration: 10 * 60, gapTolerance: 30)
    )
}
