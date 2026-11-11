import Foundation

/// A clip the camera kept for the day's highlight reel.
public struct ReelCandidate: Codable, Sendable, Hashable, Identifiable {
    public var eventID: UUID
    public var type: EventType
    /// forbiddenZone only: `"sofa"` or `"offLimits"`.
    public var place: String?
    public var startedAt: Date
    /// Length of the recorded clip, in seconds.
    public var clipDuration: TimeInterval
    public var confidence: Double

    public var id: UUID { eventID }

    public init(
        eventID: UUID,
        type: EventType,
        place: String? = nil,
        startedAt: Date,
        clipDuration: TimeInterval,
        confidence: Double
    ) {
        self.eventID = eventID
        self.type = type
        self.place = place
        self.startedAt = startedAt
        self.clipDuration = clipDuration
        self.confidence = confidence
    }

    /// Where a forbiddenZone event happened, like the backend says it: `"sofa"` when every
    /// off-limits zone on the camera is a sofa, `"offLimits"` otherwise; nil for other events.
    public static func place(for type: EventType, zones: [CameraZone]) -> String? {
        guard type == .forbiddenZone else { return nil }
        let offLimits = zones.filter(\.kind.isOffLimits)
        return !offLimits.isEmpty && offLimits.allSatisfy { $0.kind == .sofa } ? "sofa" : "offLimits"
    }

    /// What kind of moment this is, for ranking and variety.
    public var moment: ReelMoment? {
        switch type {
        case .forbiddenZone: place == "sofa" ? ReelMoment.sofa : ReelMoment.offLimits
        case .atDoor: .door
        case .prolongedBarking: .barking
        case .whining: .whining
        default: nil
        }
    }
}

/// The moments a reel is made of, best first.
public enum ReelMoment: String, Codable, Sendable, CaseIterable {
    case sofa, door, barking, offLimits, whining

    /// How much a moment of this kind is worth in a reel (the funny ones first).
    var weight: Double {
        switch self {
        case .sofa: 3
        case .door: 2.5
        case .barking: 2
        case .offLimits: 1.8
        case .whining: 1.2
        }
    }
}

/// One piece of the reel: a time range inside a kept clip.
public struct ReelSegment: Sendable, Hashable {
    public var eventID: UUID
    /// Where to start inside the clip, in seconds.
    public var start: TimeInterval
    public var duration: TimeInterval

    public init(eventID: UUID, start: TimeInterval, duration: TimeInterval) {
        self.eventID = eventID
        self.start = start
        self.duration = duration
    }
}

/// Picks the day's best 3–5 clips and how much of each to show, so the reel lands at 20–30 s
/// with the end card. Pure, so the camera's AVFoundation code only has to stitch what it says.
public struct HighlightReelPlanner: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var minClips: Int = 3
        public var maxClips: Int = 5
        /// Seconds of dog footage, before the end card.
        public var targetFootage: TimeInterval = 24
        public var minSegment: TimeInterval = 4
        public var maxSegment: TimeInterval = 8
        /// Seconds shown from before the trigger (clips start ~5 s before it).
        public var leadIn: TimeInterval = 2
        public var preRoll: TimeInterval = 5
        /// At most this many clips of the same kind, so the reel isn't six barks in a row.
        public var maxPerMoment: Int = 2
        /// Two picks of the same kind must be at least this far apart (one long episode is one moment).
        public var minGap: TimeInterval = 10 * 60
        /// The end card the camera appends ("Dog Monitor").
        public var endCard: TimeInterval = 2

        public init() {}
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// The segments in the order they play (by time of day), or nil when the day had too few
    /// moments for a reel.
    public func plan(_ candidates: [ReelCandidate]) -> [ReelSegment]? {
        let config = configuration
        let usable = candidates.filter { $0.moment != nil && $0.clipDuration >= config.minSegment }
        let ranked = usable.sorted { lhs, rhs in
            let left = score(lhs), right = score(rhs)
            if left != right { return left > right }
            return lhs.startedAt < rhs.startedAt
        }

        var picked: [ReelCandidate] = []
        for candidate in ranked where picked.count < config.maxClips {
            let sameKind = picked.filter { $0.moment == candidate.moment }
            guard sameKind.count < config.maxPerMoment else { continue }
            let tooClose = sameKind.contains { abs($0.startedAt.timeIntervalSince(candidate.startedAt)) < config.minGap }
            guard !tooClose else { continue }
            picked.append(candidate)
        }
        guard picked.count >= config.minClips else { return nil }

        let share = min(config.maxSegment, max(config.minSegment, config.targetFootage / Double(picked.count)))
        return picked
            .sorted { $0.startedAt < $1.startedAt }
            .map { candidate in
                let length = min(share, candidate.clipDuration)
                let start = max(0, min(config.preRoll - config.leadIn, candidate.clipDuration - length))
                return ReelSegment(eventID: candidate.eventID, start: start, duration: length)
            }
    }

    /// Total length of a planned reel, end card included.
    public func duration(of segments: [ReelSegment]) -> TimeInterval {
        segments.reduce(configuration.endCard) { $0 + $1.duration }
    }

    private func score(_ candidate: ReelCandidate) -> Double {
        (candidate.moment?.weight ?? 0) + min(max(candidate.confidence, 0), 1)
    }
}

/// The camera's list of clips kept for reels (the uploader deletes its own copies). Codable so
/// it survives relaunches; old entries are pruned so the phone's storage stays small.
public struct ReelClipLibrary: Codable, Sendable, Equatable {
    /// Kept long enough to build yesterday's reel after midnight.
    public static let maxAge: TimeInterval = 36 * 3600
    public static let maxCount = 60

    public private(set) var clips: [ReelCandidate] = []

    public init(clips: [ReelCandidate] = []) {
        self.clips = clips
    }

    /// Adds a clip (once per event). Returns the ids whose files should be deleted.
    @discardableResult
    public mutating func add(_ clip: ReelCandidate, now: Date) -> [UUID] {
        if !clips.contains(where: { $0.eventID == clip.eventID }) {
            clips.append(clip)
        }
        return prune(now: now)
    }

    /// Drops clips that are too old, then the oldest beyond `maxCount`. Returns the dropped ids.
    @discardableResult
    public mutating func prune(now: Date) -> [UUID] {
        let fresh = clips.filter { now.timeIntervalSince($0.startedAt) <= Self.maxAge }
        let kept = Array(fresh.sorted { $0.startedAt < $1.startedAt }.suffix(Self.maxCount))
        let keptIDs = Set(kept.map(\.eventID))
        let dropped = clips.map(\.eventID).filter { !keptIDs.contains($0) }
        clips = kept
        return dropped
    }

    /// The clips recorded on one local day (`date` is "YYYY-MM-DD" in `calendar`'s time zone).
    public func clipsRecorded(on date: String, calendar: Calendar) -> [ReelCandidate] {
        clips.filter { DailySummaryAccumulator.dateKey($0.startedAt, calendar: calendar) == date }
    }
}
