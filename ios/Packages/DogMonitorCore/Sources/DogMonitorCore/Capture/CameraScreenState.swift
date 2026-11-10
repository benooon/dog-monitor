import Foundation

/// What the camera-mode screen shows (SPEC §7, §8).
///
/// The screen is black at minimum brightness by default, to save power and heat.
/// A tap reveals the live preview and the stop button; it hides again after
/// `previewTimeout` without interaction. Time is passed in so this is testable.
public struct CameraScreenState: Sendable, Equatable {
    public static let defaultPreviewTimeout: TimeInterval = 15

    public let previewTimeout: TimeInterval
    public private(set) var previewVisibleUntil: Date?

    public init(previewTimeout: TimeInterval = Self.defaultPreviewTimeout) {
        self.previewTimeout = max(previewTimeout, 1)
    }

    public func isPreviewVisible(at now: Date) -> Bool {
        guard let previewVisibleUntil else { return false }
        return now < previewVisibleUntil
    }

    /// Brightness the screen should use: dimmed while black, normal while the preview shows.
    /// `nil` means "restore the user's own brightness".
    public func screenBrightness(at now: Date) -> Double? {
        isPreviewVisible(at: now) ? nil : 0
    }

    /// A tap on the black screen shows the preview; a tap on the preview hides it.
    public mutating func tap(at now: Date) {
        if isPreviewVisible(at: now) {
            previewVisibleUntil = nil
        } else {
            previewVisibleUntil = now.addingTimeInterval(previewTimeout)
        }
    }

    /// Any interaction with the visible preview (e.g. touching a control) keeps it up longer.
    public mutating func keepAlive(at now: Date) {
        guard isPreviewVisible(at: now) else { return }
        previewVisibleUntil = now.addingTimeInterval(previewTimeout)
    }

    public mutating func hidePreview() {
        previewVisibleUntil = nil
    }
}
