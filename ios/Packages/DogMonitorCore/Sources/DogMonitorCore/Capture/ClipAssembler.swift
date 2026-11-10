import Foundation

/// A piece of encoded media (e.g. one fragmented-MP4 segment) on the capture clock.
public struct MediaSegment<Payload: Sendable>: Sendable {
    /// Start time in seconds on the capture clock.
    public var start: TimeInterval
    public var duration: TimeInterval
    public var payload: Payload

    public var end: TimeInterval { start + duration }

    public init(start: TimeInterval, duration: TimeInterval, payload: Payload) {
        self.start = start
        self.duration = duration
        self.payload = payload
    }
}

/// The segments that make up one event's clip, oldest first.
public struct AssembledClip<Payload: Sendable>: Sendable {
    public var id: UUID
    public var segments: [MediaSegment<Payload>]

    public var start: TimeInterval? { segments.first?.start }
    public var end: TimeInterval? { segments.last?.end }
    public var duration: TimeInterval {
        guard let start, let end else { return 0 }
        return end - start
    }
}

/// Ring buffer + clip state machine for event clips (SPEC §5: 10–20 s, including ~5 s from
/// before the event). Pure: the recorder feeds it encoded segments and triggers; it says which
/// segments belong to which clip and when a clip is complete.
public struct ClipAssembler<Payload: Sendable>: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Seconds of media kept from before the trigger.
        public var preRoll: TimeInterval
        /// Seconds recorded after the trigger.
        public var postRoll: TimeInterval
        /// Hard cap on a clip's length.
        public var maxDuration: TimeInterval

        public init(preRoll: TimeInterval = 5, postRoll: TimeInterval = 10, maxDuration: TimeInterval = 20) {
            self.preRoll = preRoll
            self.postRoll = postRoll
            self.maxDuration = maxDuration
        }
    }

    private struct Pending: Sendable {
        var id: UUID
        var endTarget: TimeInterval
        var segments: [MediaSegment<Payload>]
    }

    public let configuration: Configuration
    private var ring: [MediaSegment<Payload>] = []
    private var pending: [Pending] = []

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Segments currently held for pre-roll.
    public var bufferedDuration: TimeInterval {
        guard let first = ring.first, let last = ring.last else { return 0 }
        return last.end - first.start
    }

    public var pendingClipIDs: [UUID] { pending.map(\.id) }

    /// Starts a clip for `id` at capture time `time`. A repeated id is ignored.
    public mutating func trigger(id: UUID, at time: TimeInterval) {
        guard !pending.contains(where: { $0.id == id }) else { return }
        let preRollStart = time - configuration.preRoll
        let earlier = ring.filter { $0.end > preRollStart }
        pending.append(Pending(id: id, endTarget: time + configuration.postRoll, segments: earlier))
    }

    /// Adds the next segment and returns the clips it completed.
    public mutating func append(_ segment: MediaSegment<Payload>) -> [AssembledClip<Payload>] {
        ring.append(segment)
        trimRing()

        var finished: [AssembledClip<Payload>] = []
        var stillPending: [Pending] = []
        for var clip in pending {
            let wouldExceedCap = clip.segments.first.map { segment.end - $0.start > configuration.maxDuration } ?? false
            if wouldExceedCap, !clip.segments.isEmpty {
                // Adding this segment would break the cap: the clip ends before it.
                finished.append(AssembledClip(id: clip.id, segments: clip.segments))
                continue
            }
            clip.segments.append(segment)
            if segment.end >= clip.endTarget {
                finished.append(AssembledClip(id: clip.id, segments: clip.segments))
            } else {
                stillPending.append(clip)
            }
        }
        pending = stillPending
        return finished
    }

    /// Ends every pending clip with what it has (e.g. when recording stops or restarts).
    /// The ring is cleared too, since later segments may not continue these.
    public mutating func finishAll() -> [AssembledClip<Payload>] {
        let finished = pending
            .filter { !$0.segments.isEmpty }
            .map { AssembledClip(id: $0.id, segments: $0.segments) }
        pending = []
        ring = []
        return finished
    }

    /// Drops the oldest segments while the rest still cover the pre-roll.
    private mutating func trimRing() {
        guard let last = ring.last else { return }
        while ring.count > 1, last.end - ring[1].start >= configuration.preRoll {
            ring.removeFirst()
        }
    }
}
