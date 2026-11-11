import Foundation

/// Size of the vertical (9:16) highlight reel player in a list row.
///
/// The player fills the row width, unless that would make it taller than
/// `maxHeight` (about 60% of the screen); then it keeps 9:16 at that height.
public enum ReelPlayerLayout {
    public static let aspectRatio: Double = 9.0 / 16.0
    /// Share of the visible screen height the player may take.
    public static let maxHeightFraction: Double = 0.6

    public struct Size: Equatable, Sendable {
        public let width: Double
        public let height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    /// - Parameters:
    ///   - availableWidth: the row's content width. Zero or less while not measured yet.
    ///   - containerHeight: the visible height of the list. Zero or less means no cap.
    public static func size(availableWidth: Double, containerHeight: Double) -> Size {
        guard availableWidth > 0, availableWidth.isFinite else { return Size(width: 0, height: 0) }
        var height = availableWidth / aspectRatio
        if containerHeight > 0, containerHeight.isFinite {
            height = min(height, containerHeight * maxHeightFraction)
        }
        return Size(width: height * aspectRatio, height: height)
    }
}
