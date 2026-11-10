import Foundation

/// Decides when the camera publishes video (SPEC §3): only while someone watches, and until
/// `linger` seconds after the last viewer left, so a quick re-open doesn't restart the stream.
public struct PublishPolicy: Sendable, Equatable {
    public static let defaultLinger: TimeInterval = 30

    public let linger: TimeInterval
    public private(set) var viewerCount = 0
    /// When the last viewer left, while nobody is watching.
    public private(set) var lastViewerLeftAt: Date?

    public init(linger: TimeInterval = Self.defaultLinger) {
        self.linger = max(linger, 0)
    }

    public mutating func viewersChanged(to count: Int, at now: Date) {
        let count = max(count, 0)
        if count == 0, viewerCount > 0 {
            lastViewerLeftAt = now
        } else if count > 0 {
            lastViewerLeftAt = nil
        }
        viewerCount = count
    }

    /// The realtime connection dropped: we no longer know who watches, so wind down as if all left.
    public mutating func connectionLost(at now: Date) {
        viewersChanged(to: 0, at: now)
    }

    public func shouldPublish(at now: Date) -> Bool {
        if viewerCount > 0 { return true }
        guard let lastViewerLeftAt else { return false }
        return now.timeIntervalSince(lastViewerLeftAt) < linger
    }

    /// When publishing should stop if nothing changes, or nil if it shouldn't (or already has).
    public func stopDeadline(after now: Date) -> Date? {
        guard viewerCount == 0, let lastViewerLeftAt else { return nil }
        let deadline = lastViewerLeftAt.addingTimeInterval(linger)
        return deadline > now ? deadline : nil
    }
}
