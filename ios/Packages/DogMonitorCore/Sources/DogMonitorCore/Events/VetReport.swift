import Foundation

/// "Share with your vet" (Premium): one camera's last 30 finished days as a table, with daily
/// averages. Pure; the app lays it out on a PDF page.
public struct VetReport: Sendable, Equatable {
    /// What a vet asks about, for one day or as a daily average.
    public struct Figures: Sendable, Equatable {
        public let restMinutes: Int
        public let restlessMinutes: Int
        public let barkCount: Int
        public let whiningMinutes: Int
        public let atDoorMinutes: Int
        public let activeMinutes: Int

        public init(restMinutes: Int, restlessMinutes: Int, barkCount: Int, whiningMinutes: Int, atDoorMinutes: Int, activeMinutes: Int) {
            self.restMinutes = restMinutes
            self.restlessMinutes = restlessMinutes
            self.barkCount = barkCount
            self.whiningMinutes = whiningMinutes
            self.atDoorMinutes = atDoorMinutes
            self.activeMinutes = activeMinutes
        }

        init(_ day: DailySummary) {
            self.init(
                restMinutes: day.restMinutes,
                restlessMinutes: day.minutes(in: .restless),
                barkCount: day.barkCount,
                whiningMinutes: day.minutes(in: .whining),
                atDoorMinutes: day.minutes(in: .atDoor),
                activeMinutes: day.activityByHour.prefix(24).reduce(0) { $0 + max(0, $1) }
            )
        }
    }

    public struct Row: Sendable, Equatable, Identifiable {
        /// "YYYY-MM-DD" in the camera's time zone.
        public let date: String
        public let figures: Figures
        public var id: String { date }
    }

    public static let days = 30

    /// Finished days within the 30 days ending on the newest one, oldest first.
    public let rows: [Row]

    public var from: String? { rows.first?.date }
    public var to: String? { rows.last?.date }
    public var isEmpty: Bool { rows.isEmpty }

    /// Per-day averages over `rows`, rounded; nil without rows.
    public var average: Figures? {
        guard !rows.isEmpty else { return nil }
        func mean(_ value: (Figures) -> Int) -> Int {
            Int((Double(rows.reduce(0) { $0 + value($1.figures) }) / Double(rows.count)).rounded())
        }
        return Figures(
            restMinutes: mean(\.restMinutes),
            restlessMinutes: mean(\.restlessMinutes),
            barkCount: mean(\.barkCount),
            whiningMinutes: mean(\.whiningMinutes),
            atDoorMinutes: mean(\.atDoorMinutes),
            activeMinutes: mean(\.activeMinutes)
        )
    }

    /// - Parameter summaries: one camera's days, in any order. Today so far is left out.
    public init(summaries: [DailySummaryDTO]) {
        let finished = summaries.filter(\.isFinal)
        guard let end = finished.map(\.date).max(),
              let start = DayKey.shift(end, by: -(Self.days - 1)) else {
            rows = []
            return
        }
        var seen = Set<String>()
        rows = finished
            .filter { $0.date >= start && $0.date <= end && seen.insert($0.date).inserted }
            .sorted { $0.date < $1.date }
            .map { Row(date: $0.date, figures: Figures($0.summary)) }
    }
}
