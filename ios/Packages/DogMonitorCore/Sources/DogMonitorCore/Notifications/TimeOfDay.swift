import Foundation

/// A wall-clock time ("22:00"), as the backend stores quiet hours.
public struct TimeOfDay: Hashable, Sendable, Comparable {
    public let hour: Int
    public let minute: Int

    public init?(hour: Int, minute: Int) {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    /// Parses "HH:MM" (and tolerates Postgres' "HH:MM:SS").
    public init?(_ text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1])
        else { return nil }
        self.init(hour: hour, minute: minute)
    }

    public var minutesSinceMidnight: Int { hour * 60 + minute }

    /// "HH:MM", the wire format.
    public var wireValue: String {
        Self.twoDigits(hour) + ":" + Self.twoDigits(minute)
    }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.minutesSinceMidnight < rhs.minutesSinceMidnight
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

/// A daily window in which non-urgent pushes are held back. It may wrap midnight (22:00–07:00).
public struct QuietHours: Hashable, Sendable {
    public var start: TimeOfDay
    public var end: TimeOfDay

    public init(start: TimeOfDay, end: TimeOfDay) {
        self.start = start
        self.end = end
    }

    /// What we suggest when someone turns quiet hours on: 22:00–07:00.
    public static let suggested = QuietHours(
        start: TimeOfDay(hour: 22, minute: 0)!,
        end: TimeOfDay(hour: 7, minute: 0)!
    )

    /// Whether `time` falls in [start, end); matches the backend's `inQuietHours`.
    public func contains(_ time: TimeOfDay) -> Bool {
        if start == end { return false }
        if start < end { return start <= time && time < end }
        return time >= start || time < end
    }
}
