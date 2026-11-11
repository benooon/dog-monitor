import Foundation

/// Tells a wrong live key apart from a short glitch on the viewer.
///
/// LiveKit reports each encrypted track's frame state (ok, missing key, decryption failed).
/// A single failure can happen while keys settle after joining, so the viewer only gives up
/// and asks to scan the invite code again once frames have kept failing for `grace`, with no
/// frame decrypted in between.
public struct LiveDecryptionWatch: Sendable {
    public enum FrameState: Sendable, Equatable {
        case ok
        case failing
        /// Anything that says nothing about the key (new, ratcheted, encryption side).
        case neutral
    }

    public static let defaultGrace: TimeInterval = 4

    public let grace: TimeInterval
    private var failingSince: Date?
    private var hasDecrypted = false

    public init(grace: TimeInterval = LiveDecryptionWatch.defaultGrace) {
        self.grace = grace
    }

    public mutating func record(_ state: FrameState, at time: Date) {
        switch state {
        case .ok:
            failingSince = nil
            hasDecrypted = true
        case .failing:
            if failingSince == nil { failingSince = time }
        case .neutral:
            break
        }
    }

    /// The key on this phone doesn't open the camera's video.
    public func isWrongKey(at time: Date) -> Bool {
        guard let failingSince else { return false }
        return time.timeIntervalSince(failingSince) >= grace
    }

    /// Video was decrypted at least once in this session (the key worked).
    public var keyWorked: Bool { hasDecrypted }
}
