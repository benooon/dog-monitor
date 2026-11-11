import Foundation

/// Week-over-week trends for one camera (Premium): "Rex barked 40% less this week", "on the sofa
/// 3 times, all after 2 pm". Pure: computed from the stored days and the camera's sofa visits.
///
/// "This week" is the seven days ending on the newest finished day (today so far would make every
/// week look calmer), "last week" the seven before. Averages per stored day keep a day the camera
/// was off from skewing the comparison.
public struct WeeklyInsights: Sendable, Equatable {
    public enum Trend: Sendable, Equatable, Hashable {
        /// Average barks a day compared with last week, in percent (negative: less barking).
        case barking(percent: Int)
        /// Sofa visits this week. `allAfterHour`: every visit started at or after this local hour
        /// (only said for two or more visits, all from noon on).
        case sofa(visits: Int, allAfterHour: Int?)
        /// Average rest a day compared with last week, in minutes (negative: less rest).
        case rest(minutesPerDay: Int)
        /// The local hour with the most motion over the week.
        case busiestHour(Int)
    }

    public static let daysPerWeek = 7
    /// Each week needs this many stored days before the two are compared.
    public static let minimumDays = 4
    /// Smaller changes are noise, not a trend.
    public static let minimumBarkChangePercent = 15
    public static let minimumRestChangeMinutes = 30

    /// "YYYY-MM-DD" of this week's last day; nil without a finished day.
    public let weekEnding: String?
    public let daysThisWeek: Int
    public let daysLastWeek: Int
    /// Most telling first: barking, sofa, rest, busiest hour.
    public let trends: [Trend]

    /// Both weeks have enough days to compare.
    public var canCompare: Bool {
        daysThisWeek >= Self.minimumDays && daysLastWeek >= Self.minimumDays
    }

    /// - Parameters:
    ///   - summaries: one camera's days, in any order.
    ///   - sofaVisits: start times of that camera's sofa events (outside this week is ignored).
    ///   - calendar: the calendar the camera counts days in.
    public init(summaries: [DailySummaryDTO], sofaVisits: [Date] = [], calendar: Calendar) {
        guard let end = summaries.filter(\.isFinal).map(\.date).max() else {
            weekEnding = nil
            daysThisWeek = 0
            daysLastWeek = 0
            trends = []
            return
        }
        let thisWeekDates = Set(DayKey.days(endingAt: end, count: Self.daysPerWeek))
        let lastWeekDates = DayKey.shift(end, by: -Self.daysPerWeek)
            .map { Set(DayKey.days(endingAt: $0, count: Self.daysPerWeek)) } ?? []
        var byDate: [String: DailySummary] = [:]
        for dto in summaries where byDate[dto.date] == nil {
            byDate[dto.date] = dto.summary
        }
        let thisWeek = thisWeekDates.compactMap { byDate[$0] }
        let lastWeek = lastWeekDates.compactMap { byDate[$0] }

        weekEnding = end
        daysThisWeek = thisWeek.count
        daysLastWeek = lastWeek.count
        let compare = thisWeek.count >= Self.minimumDays && lastWeek.count >= Self.minimumDays

        var trends: [Trend] = []
        if compare {
            let barksNow = Self.average(thisWeek.map(\.barkCount))
            let barksBefore = Self.average(lastWeek.map(\.barkCount))
            if barksBefore >= 1 {
                let percent = Int(((barksNow - barksBefore) / barksBefore * 100).rounded())
                if abs(percent) >= Self.minimumBarkChangePercent {
                    trends.append(.barking(percent: percent))
                }
            }
        }

        let visits = sofaVisits.filter { thisWeekDates.contains(DailySummaryAccumulator.dateKey($0, calendar: calendar)) }
        if !visits.isEmpty {
            let earliestHour = visits.map { calendar.component(.hour, from: $0) }.min() ?? 0
            let allAfter = visits.count >= 2 && earliestHour >= 12 ? earliestHour : nil
            trends.append(.sofa(visits: visits.count, allAfterHour: allAfter))
        }

        if compare {
            let restChange = Int((Self.average(thisWeek.map(\.restMinutes)) - Self.average(lastWeek.map(\.restMinutes))).rounded())
            if abs(restChange) >= Self.minimumRestChangeMinutes {
                trends.append(.rest(minutesPerDay: restChange))
            }
        }

        var activity = Array(repeating: 0, count: 24)
        for day in thisWeek {
            for (hour, minutes) in day.activityByHour.prefix(24).enumerated() {
                activity[hour] += max(0, minutes)
            }
        }
        if let peak = activity.max(), peak > 0, let hour = activity.firstIndex(of: peak) {
            trends.append(.busiestHour(hour))
        }
        self.trends = trends
    }

    private static func average(_ values: [Int]) -> Double {
        values.isEmpty ? 0 : Double(values.reduce(0, +)) / Double(values.count)
    }
}

/// Arithmetic on "YYYY-MM-DD" keys, independent of any time zone.
enum DayKey {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// `key` moved by `days` (negative: earlier); nil for a malformed key.
    static func shift(_ key: String, by days: Int) -> String? {
        guard let date = DailySummaryInsights.date(from: key, calendar: calendar),
              let moved = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return DailySummaryAccumulator.dateKey(moved, calendar: calendar)
    }

    /// `count` keys ending at `end`, oldest first.
    static func days(endingAt end: String, count: Int) -> [String] {
        (0..<max(count, 0)).reversed().compactMap { shift(end, by: -$0) }
    }
}
