import Foundation

/// An event produced by the event engine and stored in the timeline (SPEC §5, §9 `events`).
public struct DogEvent: Codable, Sendable, Hashable, Identifiable {
    public enum Feedback: String, Codable, Sendable, Hashable {
        case correct
        case wrong
    }

    public var id: UUID
    public var cameraID: UUID
    public var type: EventType
    public var state: DogState?
    public var startedAt: Date
    public var endedAt: Date?
    public var confidence: Double
    public var clipKey: String?
    public var snapshotKey: String?
    public var feedback: Feedback?

    public init(
        id: UUID = UUID(),
        cameraID: UUID,
        type: EventType,
        state: DogState? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        confidence: Double,
        clipKey: String? = nil,
        snapshotKey: String? = nil,
        feedback: Feedback? = nil
    ) {
        self.id = id
        self.cameraID = cameraID
        self.type = type
        self.state = state ?? type.dogState
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.confidence = confidence
        self.clipKey = clipKey
        self.snapshotKey = snapshotKey
        self.feedback = feedback
    }

    public var isOngoing: Bool { endedAt == nil }

    /// Duration so far (or total, once ended).
    public func duration(now: Date) -> TimeInterval {
        (endedAt ?? now).timeIntervalSince(startedAt)
    }
}
