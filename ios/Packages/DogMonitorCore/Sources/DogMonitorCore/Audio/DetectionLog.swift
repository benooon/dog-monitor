import Foundation

/// Recent detections, for the camera-mode debug overlay.
public struct DetectionLog: Sendable, Equatable {
    public let capacity: Int
    public private(set) var entries: [Detection] = []

    public init(capacity: Int = 50) {
        self.capacity = max(capacity, 1)
    }

    public mutating func append(_ detection: Detection) {
        entries.append(detection)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Newest first.
    public func latest(_ count: Int) -> [Detection] {
        Array(entries.suffix(max(count, 0)).reversed())
    }

    /// How many detections of `kind` happened in the `window` seconds before `now`.
    public func count(of kind: Detection.Kind, within window: TimeInterval, before now: Date) -> Int {
        let start = now.addingTimeInterval(-window)
        return entries.filter { $0.kind == kind && $0.timestamp > start && $0.timestamp <= now }.count
    }
}
