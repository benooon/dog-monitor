import Foundation

/// Measures frames per second over a sliding window, from frame timestamps in seconds
/// (e.g. sample buffer presentation times). Used by the camera debug indicator and health.
public struct FrameRateMeter: Sendable, Equatable {
    public let window: Double
    private var timestamps: [Double] = []

    public init(window: Double = 2) {
        self.window = max(window, 0.1)
    }

    public mutating func record(_ timestamp: Double) {
        // Out-of-order or reset clocks (e.g. capture restarted) start a fresh window.
        if let last = timestamps.last, timestamp < last {
            timestamps.removeAll()
        }
        timestamps.append(timestamp)
        let cutoff = timestamp - window
        if let firstKept = timestamps.firstIndex(where: { $0 > cutoff }), firstKept > 0 {
            timestamps.removeFirst(firstKept)
        }
    }

    /// Frames per second across the current window, or 0 with fewer than two frames.
    public var framesPerSecond: Double {
        guard timestamps.count >= 2, let first = timestamps.first, let last = timestamps.last, last > first else {
            return 0
        }
        return Double(timestamps.count - 1) / (last - first)
    }
}
