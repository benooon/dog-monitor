/// A rectangle in normalized image coordinates (0...1, origin top-left).
/// Kept platform-independent so it can be used on Linux (no CGRect).
public struct NormalizedRect: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}
