import Foundation
import XCTest
@testable import DogMonitorCore

final class WeeklyInsightsTests: XCTestCase {
    private let camera = UUID()
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Jerusalem")!
        return calendar
    }()

    private func dto(_ date: String, rest: Int = 0, barks: Int = 0, activity: [Int]? = nil, states: [String: Int] = [:], final: Bool = true) -> DailySummaryDTO {
        DailySummaryDTO(
            cameraId: camera,
            date: date,
            restMinutes: rest,
            barkCount: barks,
            activityByHour: activity ?? Array(repeating: 0, count: 24),
            stateMinutes: states,
            isFinal: final
        )
    }

    /// Days 2026-11-(first...last), all with the same numbers.
    private func days(_ first: Int, _ last: Int, rest: Int = 0, barks: Int = 0) -> [DailySummaryDTO] {
        (first...last).map { dto(String(format: "2026-11-%02d", $0), rest: rest, barks: barks) }
    }

    private func at(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: 10))!
    }

    func testDayKeyArithmeticCrossesMonths() {
        XCTAssertEqual(DayKey.shift("2026-11-01", by: -1), "2026-10-31")
        XCTAssertEqual(DayKey.shift("2026-12-31", by: 1), "2027-01-01")
        XCTAssertEqual(DayKey.days(endingAt: "2026-11-02", count: 3), ["2026-10-31", "2026-11-01", "2026-11-02"])
        XCTAssertNil(DayKey.shift("soon", by: 1))
    }

    func testNoFinishedDayHasNoInsights() {
        let insights = WeeklyInsights(summaries: [dto("2026-11-10", barks: 9, final: false)], calendar: calendar)
        XCTAssertNil(insights.weekEnding)
        XCTAssertEqual(insights.trends, [])
        XCTAssertFalse(insights.canCompare)
    }

    func testBarkingDownFortyPercentWeekOverWeek() {
        // Last week 2–8 Nov: 10 barks a day; this week 9–15 Nov: 6 a day. Today (16th) isn't final.
        let summaries = days(2, 8, rest: 400, barks: 10) + days(9, 15, rest: 410, barks: 6) + [dto("2026-11-16", barks: 50, final: false)]
        let insights = WeeklyInsights(summaries: summaries, calendar: calendar)
        XCTAssertEqual(insights.weekEnding, "2026-11-15")
        XCTAssertEqual(insights.daysThisWeek, 7)
        XCTAssertEqual(insights.daysLastWeek, 7)
        XCTAssertTrue(insights.canCompare)
        // Rest changed by only 10 min a day: not a trend.
        XCTAssertEqual(insights.trends, [.barking(percent: -40)])
    }

    func testSmallChangesAndEmptyWeeksAreNotTrends() {
        let summaries = days(2, 8, barks: 10) + days(9, 15, barks: 11)
        XCTAssertEqual(WeeklyInsights(summaries: summaries, calendar: calendar).trends, [])
        // No barking last week: a percentage would mean nothing.
        XCTAssertEqual(WeeklyInsights(summaries: days(2, 8) + days(9, 15, barks: 4), calendar: calendar).trends, [])
    }

    func testNeedsFourDaysInEachWeekToCompare() {
        let summaries = days(6, 8, rest: 100, barks: 30) + days(9, 15, rest: 500, barks: 2)
        let insights = WeeklyInsights(summaries: summaries, calendar: calendar)
        XCTAssertEqual(insights.daysLastWeek, 3)
        XCTAssertFalse(insights.canCompare)
        XCTAssertEqual(insights.trends, [])
    }

    func testAveragesPerStoredDaySoMissingDaysDontSkew() {
        // Last week has 4 days of 300 min rest; this week 5 days of 360: +60 a day.
        let summaries = days(2, 5, rest: 300, barks: 5) + days(11, 15, rest: 360, barks: 5)
        let insights = WeeklyInsights(summaries: summaries, calendar: calendar)
        XCTAssertEqual(insights.trends, [.rest(minutesPerDay: 60)])
    }

    func testSofaVisitsThisWeekAllAfterTwo() {
        let visits = [at(10, 14), at(12, 17), at(15, 15), at(3, 9)] // the 3rd is last week
        let insights = WeeklyInsights(summaries: days(9, 15), sofaVisits: visits, calendar: calendar)
        XCTAssertEqual(insights.trends, [.sofa(visits: 3, allAfterHour: 14)])

        let mixed = WeeklyInsights(summaries: days(9, 15), sofaVisits: [at(10, 9), at(11, 16)], calendar: calendar)
        XCTAssertEqual(mixed.trends, [.sofa(visits: 2, allAfterHour: nil)])
        let once = WeeklyInsights(summaries: days(9, 15), sofaVisits: [at(11, 16)], calendar: calendar)
        XCTAssertEqual(once.trends, [.sofa(visits: 1, allAfterHour: nil)])
    }

    func testBusiestHourOverTheWeekAndOrder() {
        var evening = Array(repeating: 1, count: 24)
        evening[18] = 20
        let summaries = days(2, 8, barks: 20) + (9...15).map { dto(String(format: "2026-11-%02d", $0), barks: 10, activity: evening) }
        let insights = WeeklyInsights(summaries: summaries, sofaVisits: [at(12, 13)], calendar: calendar)
        XCTAssertEqual(insights.trends, [.barking(percent: -50), .sofa(visits: 1, allAfterHour: nil), .busiestHour(18)])
    }
}

final class VetReportTests: XCTestCase {
    private let camera = UUID()

    private func dto(_ date: String, rest: Int, barks: Int, states: [String: Int] = [:], final: Bool = true) -> DailySummaryDTO {
        var activity = Array(repeating: 0, count: 24)
        activity[9] = 30
        activity[17] = 15
        return DailySummaryDTO(cameraId: camera, date: date, restMinutes: rest, barkCount: barks, activityByHour: activity, stateMinutes: states, isFinal: final)
    }

    func testEmptyWithoutFinishedDays() {
        let report = VetReport(summaries: [dto("2026-11-11", rest: 10, barks: 1, final: false)])
        XCTAssertTrue(report.isEmpty)
        XCTAssertNil(report.average)
        XCTAssertNil(report.from)
    }

    func testLastThirtyFinishedDaysOldestFirstWithAverages() {
        var summaries = (0..<40).map { offset -> DailySummaryDTO in
            let date = DayKey.shift("2026-11-10", by: -offset)!
            return dto(date, rest: 400, barks: offset % 2 == 0 ? 4 : 7, states: ["restless": 60, "whining": 3, "atDoor": 10])
        }
        summaries.append(dto("2026-11-11", rest: 5, barks: 99, final: false)) // today so far
        let report = VetReport(summaries: summaries.shuffled())

        XCTAssertEqual(report.rows.count, 30)
        XCTAssertEqual(report.from, "2026-10-12")
        XCTAssertEqual(report.to, "2026-11-10")
        XCTAssertEqual(report.rows.first?.figures, VetReport.Figures(
            restMinutes: 400, restlessMinutes: 60, barkCount: 7, whiningMinutes: 3, atDoorMinutes: 10, activeMinutes: 45
        ))
        // 15 days of 4 barks and 15 of 7: 5.5 rounds to 6.
        XCTAssertEqual(report.average?.barkCount, 6)
        XCTAssertEqual(report.average?.restMinutes, 400)
        XCTAssertEqual(report.average?.activeMinutes, 45)
    }

    func testMissingDaysAreLeftOut() {
        let report = VetReport(summaries: [dto("2026-11-01", rest: 300, barks: 2), dto("2026-11-10", rest: 500, barks: 4)])
        XCTAssertEqual(report.rows.map(\.date), ["2026-11-01", "2026-11-10"])
        XCTAssertEqual(report.average?.restMinutes, 400)
        XCTAssertEqual(report.average?.barkCount, 3)
    }
}
