import Foundation

/// Tracks one kind of episode (e.g. barking) and turns hits into event lifecycle changes.
struct EventChannel: Sendable {
    let config: ChannelConfiguration

    private(set) var episodeStart: Date?
    private(set) var lastSeen: Date?
    private var recentHits: [Date] = []
    private var peakConfidence = 0.0

    private(set) var activeEvent: DogEvent?
    private(set) var lastEndedEvent: DogEvent?
    private var escalationsSent = 0

    init(config: ChannelConfiguration) {
        self.config = config
    }

    func isActive(at now: Date) -> Bool {
        guard let lastSeen else { return false }
        return now.timeIntervalSince(lastSeen) <= config.gapTolerance
    }

    /// Records a hit. Call `evaluate` afterwards.
    mutating func hit(at time: Date, confidence: Double) {
        if !isActive(at: time) {
            episodeStart = time
            peakConfidence = 0
        }
        lastSeen = max(lastSeen ?? time, time)
        recentHits.append(time)
        let countWindow = config.countWindow // a local copy: the closure must not read self while recentHits is mutated
        recentHits.removeAll { time.timeIntervalSince($0) > countWindow }
        peakConfidence = max(peakConfidence, confidence)
    }

    /// When the current activity qualifies as an event, returns when it started.
    /// Hits are counted across short episodes within `countWindow` ("Y barks within a minute").
    private func qualifyingStart() -> Date? {
        guard let start = episodeStart, let lastSeen else { return nil }
        if lastSeen.timeIntervalSince(start) >= config.minDuration { return start }
        if let countThreshold = config.countThreshold, recentHits.count >= countThreshold, let first = recentHits.first {
            return min(first, start)
        }
        return nil
    }

    /// Advances the channel to `now`.
    /// - Parameter mayResume: whether a qualifying episode may silently continue the last ended event.
    mutating func evaluate(now: Date, cameraID: UUID, mayResume: Bool, makeID: () -> UUID) -> [EngineOutput] {
        var outputs: [EngineOutput] = []

        if isActive(at: now) {
            if activeEvent == nil, let start = qualifyingStart() {
                if mayResume, var previous = lastEndedEvent, let endedAt = previous.endedAt,
                   start.timeIntervalSince(endedAt) < config.cooldown {
                    // Within cooldown: the same event goes on, no new push.
                    previous.endedAt = nil
                    previous.confidence = max(previous.confidence, peakConfidence)
                    activeEvent = previous
                    lastEndedEvent = nil
                    outputs.append(.resumed(previous))
                } else {
                    let event = DogEvent(
                        id: makeID(),
                        cameraID: cameraID,
                        type: config.eventType,
                        startedAt: start,
                        confidence: peakConfidence
                    )
                    activeEvent = event
                    lastEndedEvent = nil
                    escalationsSent = 0
                    outputs.append(.started(event))
                }
            }
            if var event = activeEvent {
                event.confidence = max(event.confidence, peakConfidence)
                activeEvent = event
                let duration = now.timeIntervalSince(event.startedAt)
                while escalationsSent < config.escalations.count, duration >= config.escalations[escalationsSent] {
                    outputs.append(.escalated(event, duration: config.escalations[escalationsSent]))
                    escalationsSent += 1
                }
            }
        } else if lastSeen != nil {
            // The episode is over.
            if var event = activeEvent {
                event.endedAt = lastSeen
                activeEvent = nil
                lastEndedEvent = event
                outputs.append(.ended(event))
                // These hits belonged to the event; don't let them re-trigger the count rule.
                recentHits.removeAll()
            }
            episodeStart = nil
            peakConfidence = 0
        }
        return outputs
    }
}
