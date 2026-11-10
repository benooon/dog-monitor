import Foundation

/// What the daily summary screen shows for one camera, computed from the days the backend returned
/// (`GET /summaries`). Pure, so the screen stays a thin view over it.
public struct DailySummaryInsights: Sendable, Equatable {
    public struct DayPoint: Sendable, Equatable, Identifiable {
        public let date: String
        public let restMinutes: Int
        public let barkCount: Int
        public var id: String { date }
    }

    public struct HourPoint: Sendable, Equatable, Identifiable {
        public let hour: Int
        public let activeMinutes: Int
        public var id: Int { hour }
    }

    public struct StateShare: Sendable, Equatable, Identifiable {
        public let state: DogState
        public let minutes: Int
        public var id: DogState { state }
    }

    /// The day on display (the newest one unless another was selected).
    public let day: DailySummary?
    /// The day before `day`, when the backend has it, for "compared with yesterday".
    public let previousDay: DailySummary?
    /// Up to `weekLength` days ending at `day`, oldest first, for the week chart.
    public let week: [DayPoint]

    public static let weekLength = 7

    /// - Parameters:
    ///   - summaries: one camera's days, in any order.
    ///   - selectedDate: "YYYY-MM-DD"; nil or unknown means the newest day.
    public init(summaries: [DailySummaryDTO], selectedDate: String? = nil) {
        let days = summaries.map(\.summary).sorted { $0.date < $1.date }
        let index = selectedDate.flatMap { date in days.lastIndex { $0.date == date } } ?? days.indices.last
        guard let index else {
            day = nil
            previousDay = nil
            week = []
            return
        }
        let selected = days[index]
        day = selected
        previousDay = index > 0 && Self.isDay(days[index - 1].date, before: selected.date) ? days[index - 1] : nil
        week = days[max(0, index - Self.weekLength + 1)...index]
            .map { DayPoint(date: $0.date, restMinutes: $0.restMinutes, barkCount: $0.barkCount) }
    }

    /// Dates available to pick, newest first.
    public static func dates(in summaries: [DailySummaryDTO]) -> [String] {
        Array(Set(summaries.map(\.date))).sorted(by: >)
    }

    /// 24 points, one per local hour of `day`.
    public var hourly: [HourPoint] {
        let values = day?.activityByHour ?? []
        return (0..<24).map { HourPoint(hour: $0, activeMinutes: $0 < values.count ? max(0, values[$0]) : 0) }
    }

    /// Minutes per known state, largest first (unknown and zero-minute states left out).
    public var stateShares: [StateShare] {
        guard let day else { return [] }
        return DogState.allCases
            .filter { $0 != .unknown }
            .map { StateShare(state: $0, minutes: day.minutes(in: $0)) }
            .filter { $0.minutes > 0 }
            .sorted { $0.minutes == $1.minutes ? $0.state.rawValue < $1.state.rawValue : $0.minutes > $1.minutes }
    }

    /// Barks compared with the day before (positive: more barking); nil without that day.
    public var barkChange: Int? {
        guard let day, let previousDay else { return nil }
        return day.barkCount - previousDay.barkCount
    }

    /// Rest minutes compared with the day before; nil without that day.
    public var restChange: Int? {
        guard let day, let previousDay else { return nil }
        return day.restMinutes - previousDay.restMinutes
    }

    /// Minutes with motion over the whole day.
    public var activeMinutes: Int {
        hourly.reduce(0) { $0 + $1.activeMinutes }
    }

    /// True when the camera saw nothing worth charting (e.g. it was off all day).
    public var isEmpty: Bool {
        guard let day else { return true }
        return day.restMinutes == 0 && day.barkCount == 0 && activeMinutes == 0 && stateShares.isEmpty
    }

    /// The `from` / `to` range ("YYYY-MM-DD") for the last `days` days ending today in `calendar`.
    public static func range(lastDays days: Int, now: Date, calendar: Calendar) -> (from: String, to: String) {
        let start = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: now) ?? now
        return (DailySummaryAccumulator.dateKey(start, calendar: calendar), DailySummaryAccumulator.dateKey(now, calendar: calendar))
    }

    /// Parses "YYYY-MM-DD" as the start of that day in `calendar`.
    public static func date(from key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func isDay(_ earlier: String, before later: String) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let start = date(from: earlier, calendar: calendar), let end = date(from: later, calendar: calendar) else { return false }
        return calendar.dateComponents([.day], from: start, to: end).day == 1
    }
}
