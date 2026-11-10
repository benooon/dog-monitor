import Foundation

/// A small grayscale frame for motion analysis: one byte of luma per pixel, row by row.
public struct LumaFrame: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
    public let timestamp: Date

    public init?(width: Int, height: Int, pixels: [UInt8], timestamp: Date) {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
        self.timestamp = timestamp
    }

    /// Box-downsamples a luma plane (e.g. the Y plane of a camera buffer) so its width is at most
    /// `targetWidth`, keeping the aspect ratio. Averaging also smooths sensor noise.
    public static func downsample(
        _ plane: UnsafeBufferPointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        targetWidth: Int = 64,
        timestamp: Date
    ) -> LumaFrame? {
        guard width > 0, height > 0, bytesPerRow >= width, plane.count >= bytesPerRow * (height - 1) + width,
              targetWidth > 0
        else { return nil }
        let step = max(1, Int((Double(width) / Double(targetWidth)).rounded(.up)))
        let outWidth = width / step
        let outHeight = height / step
        guard outWidth > 0, outHeight > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: outWidth * outHeight)
        let area = step * step
        for outY in 0..<outHeight {
            for outX in 0..<outWidth {
                var sum = 0
                for dy in 0..<step {
                    let row = (outY * step + dy) * bytesPerRow + outX * step
                    for dx in 0..<step {
                        sum += Int(plane[row + dx])
                    }
                }
                pixels[outY * outWidth + outX] = UInt8(sum / area)
            }
        }
        return LumaFrame(width: outWidth, height: outHeight, pixels: pixels, timestamp: timestamp)
    }
}

/// A region of the frame watched for motion (normalized, origin top-left).
public struct MotionZone: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var rect: NormalizedRect

    public init(id: String, rect: NormalizedRect) {
        self.id = id
        self.rect = rect
    }

    /// The whole frame, used when the user has not drawn any zones.
    public static let wholeFrame = MotionZone(id: "frame", rect: NormalizedRect(x: 0, y: 0, width: 1, height: 1))
}

public struct MotionDetectorConfiguration: Sendable, Hashable {
    /// Minimum luma change (0–255) for a pixel to count as changed; filters noise and flicker.
    public var pixelThreshold: Int
    /// Fraction of a zone's pixels that must change for the zone to count as moving.
    public var zoneFraction: Double
    /// If more than this fraction of the whole frame changes, it's a light change (lamp,
    /// auto-exposure), not motion.
    public var globalChangeLimit: Double
    /// Motion keeps the gate open this long after it was last seen.
    public var hold: TimeInterval
    /// Frames closer together than this are skipped (2–5 fps per SPEC §4).
    public var minimumInterval: TimeInterval

    public init(
        pixelThreshold: Int = 25,
        zoneFraction: Double = 0.02,
        globalChangeLimit: Double = 0.6,
        hold: TimeInterval = 3,
        minimumInterval: TimeInterval = 0.25
    ) {
        self.pixelThreshold = pixelThreshold
        self.zoneFraction = zoneFraction
        self.globalChangeLimit = globalChangeLimit
        self.hold = hold
        self.minimumInterval = minimumInterval
    }
}

/// What one analyzed frame showed.
public struct MotionResult: Sendable, Equatable {
    /// Fraction of changed pixels in each zone, by zone id.
    public var zoneFractions: [String: Double]
    /// Zones over the threshold.
    public var movingZones: Set<String>
    /// The changed area, when there was motion.
    public var boundingBox: NormalizedRect?
    public var timestamp: Date

    public var hasMotion: Bool { !movingZones.isEmpty }
}

/// Frame differencing between consecutive small luma frames, per zone (SPEC §4 layer 1).
/// Cheap enough to run on every analyzed frame; heavier analysis runs only while `isActive`.
public struct MotionDetector: Sendable {
    public var zones: [MotionZone]
    public let configuration: MotionDetectorConfiguration
    private var previous: LumaFrame?
    private var lastMotionAt: Date?

    public init(zones: [MotionZone] = [], configuration: MotionDetectorConfiguration = MotionDetectorConfiguration()) {
        self.zones = zones
        self.configuration = configuration
    }

    /// Whether `frame` is due for analysis (frames arrive at up to 30 fps; we look at 2–5).
    public func wants(_ timestamp: Date) -> Bool {
        guard let previous else { return true }
        return timestamp.timeIntervalSince(previous.timestamp) >= configuration.minimumInterval
    }

    /// Compares `frame` with the previous one. The first frame (or a size change) has no motion.
    public mutating func process(_ frame: LumaFrame) -> MotionResult {
        defer { previous = frame }
        let watched = zones.isEmpty ? [MotionZone.wholeFrame] : zones
        var result = MotionResult(zoneFractions: [:], movingZones: [], boundingBox: nil, timestamp: frame.timestamp)
        guard let previous, previous.width == frame.width, previous.height == frame.height else { return result }

        let threshold = configuration.pixelThreshold
        var changed = [Bool](repeating: false, count: frame.pixels.count)
        var changedCount = 0
        var minX = frame.width, minY = frame.height, maxX = -1, maxY = -1
        for index in frame.pixels.indices where abs(Int(frame.pixels[index]) - Int(previous.pixels[index])) >= threshold {
            changed[index] = true
            changedCount += 1
            let x = index % frame.width, y = index / frame.width
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        if Double(changedCount) / Double(frame.pixels.count) > configuration.globalChangeLimit {
            return result
        }

        for zone in watched {
            let x0 = Self.clamp(Int((zone.rect.x * Double(frame.width)).rounded(.down)), frame.width)
            let x1 = Self.clamp(Int(((zone.rect.x + zone.rect.width) * Double(frame.width)).rounded(.up)), frame.width)
            let y0 = Self.clamp(Int((zone.rect.y * Double(frame.height)).rounded(.down)), frame.height)
            let y1 = Self.clamp(Int(((zone.rect.y + zone.rect.height) * Double(frame.height)).rounded(.up)), frame.height)
            let total = (x1 - x0) * (y1 - y0)
            guard total > 0 else {
                result.zoneFractions[zone.id] = 0
                continue
            }
            var count = 0
            for y in y0..<y1 {
                for x in x0..<x1 where changed[y * frame.width + x] {
                    count += 1
                }
            }
            let fraction = Double(count) / Double(total)
            result.zoneFractions[zone.id] = fraction
            if fraction >= configuration.zoneFraction { result.movingZones.insert(zone.id) }
        }

        if result.hasMotion {
            lastMotionAt = frame.timestamp
            result.boundingBox = NormalizedRect(
                x: Double(minX) / Double(frame.width),
                y: Double(minY) / Double(frame.height),
                width: Double(maxX - minX + 1) / Double(frame.width),
                height: Double(maxY - minY + 1) / Double(frame.height)
            )
        }
        return result
    }

    /// The gate for heavier analysis: motion was seen within `hold`.
    public func isActive(at now: Date) -> Bool {
        guard let lastMotionAt else { return false }
        return now.timeIntervalSince(lastMotionAt) < configuration.hold
    }

    /// A `.motion` detection for the event engine, confidence growing with the moving area.
    public static func detection(for result: MotionResult) -> Detection? {
        guard result.hasMotion else { return nil }
        let strongest = result.movingZones.compactMap { result.zoneFractions[$0] }.max() ?? 0
        return Detection(kind: .motion, confidence: min(1, strongest * 10), timestamp: result.timestamp, boundingBox: result.boundingBox)
    }

    private static func clamp(_ value: Int, _ upper: Int) -> Int {
        min(max(value, 0), upper)
    }
}
