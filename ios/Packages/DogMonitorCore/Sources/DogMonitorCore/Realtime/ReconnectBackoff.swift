import Foundation

/// Exponential backoff with a cap and jitter, for reconnecting the realtime socket and LiveKit.
public struct ReconnectBackoff: Sendable, Equatable {
    public let initial: TimeInterval
    public let maximum: TimeInterval
    /// 0...1: each delay is randomly shortened by up to this fraction, to spread reconnects.
    public let jitter: Double
    public private(set) var attempt = 0

    public init(initial: TimeInterval = 1, maximum: TimeInterval = 30, jitter: Double = 0.2) {
        self.initial = max(initial, 0.01)
        self.maximum = max(maximum, self.initial)
        self.jitter = min(max(jitter, 0), 1)
    }

    /// The delay before the next attempt. `random` in 0...1 (injectable for tests).
    public mutating func nextDelay(random: Double = Double.random(in: 0...1)) -> TimeInterval {
        let base = min(initial * pow(2, Double(min(attempt, 30))), maximum)
        attempt += 1
        return base * (1 - jitter * min(max(random, 0), 1))
    }

    /// Call after a successful connection.
    public mutating func reset() {
        attempt = 0
    }
}
