import Foundation
import XCTest
@testable import DogMonitorCore

final class DailySummaryInsightsTests: XCTestCase {
    private let camera = UUID()

    private func dto(_ date: String, rest: Int = 0, barks: Int = 0, activity: [Int] = Array(repeating: 0, count: 24), states: [String: Int] = [:]) -> DailySummaryDTO {
        DailySummaryDTO(cameraId: camera, date: date, restMinutes: rest, barkCount: barks, activityByHour: activity, stateMinutes: states, isFinal: true)
    }

    func testNoDaysIsEmpty() {
        let insights = DailySummaryInsights(summaries: [])
        XCTAssertNil(insights.day)
        XCTAssertTrue(insights.isEmpty)
        XCTAssertEqual(insights.week, [])
        XCTAssertEqual(insights.hourly.count, 24)
        XCTAssertNil(insights.barkChange)
    }

    func testPicksNewestDayAndComparesWithYesterday() {
        let insights = DailySummaryInsights(summaries: [
            dto("2026-11-10", rest: 300, barks: 4),
            dto("2026-11-08", rest: 100, barks: 20),
            dto("2026-11-09", rest: 240, barks: 10),
        ])
        XCTAssertEqual(insights.day?.date, "2026-11-10")
        XCTAssertEqual(insights.previousDay?.date, "2026-11-09")
        XCTAssertEqual(insights.barkChange, -6)
        XCTAssertEqual(insights.restChange, 60)
        XCTAssertEqual(insights.week.map(\.date), ["2026-11-08", "2026-11-09", "2026-11-10"])
    }

    func testDoesNotCompareAcrossAGap() {
        let insights = DailySummaryInsights(summaries: [dto("2026-11-10", barks: 1), dto("2026-11-07", barks: 9)])
        XCTAssertNil(insights.previousDay)
        XCTAssertNil(insights.barkChange)
    }

    func testComparesAcrossMonthEnd() {
        let insights = DailySummaryInsights(summaries: [dto("2026-12-01", barks: 3), dto("2026-11-30", barks: 1)])
        XCTAssertEqual(insights.barkChange, 2)
    }

    func testSelectedDateAndWeekWindow() {
        let days = (1...10).map { dto(String(format: "2026-11-%02d", $0), barks: $0) }
        let insights = DailySummaryInsights(summaries: days, selectedDate: "2026-11-09")
        XCTAssertEqual(insights.day?.barkCount, 9)
        XCTAssertEqual(insights.week.count, DailySummaryInsights.weekLength)
        XCTAssertEqual(insights.week.first?.date, "2026-11-03")
        XCTAssertEqual(insights.week.last?.date, "2026-11-09")

        let unknown = DailySummaryInsights(summaries: days, selectedDate: "2025-01-01")
        XCTAssertEqual(unknown.day?.date, "2026-11-10")
    }

    func testHourlyAndStateShares() {
        var activity = Array(repeating: 0, count: 24)
        activity[14] = 12
        activity[9] = 3
        let insights = DailySummaryInsights(summaries: [
            dto("2026-11-10", rest: 200, activity: activity, states: ["resting": 200, "barking": 5, "restless": 40, "unknown": 99, "atDoor": 0]),
        ])
        XCTAssertEqual(insights.hourly[14].activeMinutes, 12)
        XCTAssertEqual(insights.activeMinutes, 15)
        XCTAssertEqual(insights.stateShares.map(\.state), [.resting, .restless, .barking])
        XCTAssertFalse(insights.isEmpty)
    }

    func testShortActivityArrayIsPadded() {
        let insights = DailySummaryInsights(summaries: [dto("2026-11-10", activity: [5])])
        XCTAssertEqual(insights.hourly.count, 24)
        XCTAssertEqual(insights.hourly[0].activeMinutes, 5)
        XCTAssertEqual(insights.hourly[23].activeMinutes, 0)
    }

    func testDatesNewestFirst() {
        XCTAssertEqual(DailySummaryInsights.dates(in: [dto("2026-11-08"), dto("2026-11-10"), dto("2026-11-09")]),
                       ["2026-11-10", "2026-11-09", "2026-11-08"])
    }

    func testRangeAndDateParsing() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Jerusalem")!
        // 2026-11-10 00:30 in Jerusalem is still 2026-11-09 in UTC.
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 0, minute: 30))!
        let range = DailySummaryInsights.range(lastDays: 14, now: now, calendar: calendar)
        XCTAssertEqual(range.from, "2026-10-28")
        XCTAssertEqual(range.to, "2026-11-10")

        let start = DailySummaryInsights.date(from: "2026-11-10", calendar: calendar)
        XCTAssertEqual(start, calendar.startOfDay(for: now))
        XCTAssertNil(DailySummaryInsights.date(from: "nope", calendar: calendar))
    }
}
