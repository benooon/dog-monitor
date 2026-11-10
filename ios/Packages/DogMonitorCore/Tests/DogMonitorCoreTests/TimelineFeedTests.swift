import Foundation
import XCTest
@testable import DogMonitorCore

final class TimelineFeedTests: XCTestCase {
    private static let household = UUID(uuidString: Fixtures.householdID)!
    private static let camera = UUID(uuidString: Fixtures.deviceID)!

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// An event starting `hoursAgo` hours before 2026-11-10 12:00 UTC.
    private static func event(
        _ n: Int,
        hoursAgo: Double = 0,
        type: EventType = .prolongedBarking,
        feedback: DogEvent.Feedback? = nil
    ) -> EventDTO {
        let base = Date(timeIntervalSince1970: 1_794_312_000) // 2026-11-10T12:00:00Z
        return EventDTO(
            id: UUID(uuidString: "00000000-0000-4000-8000-" + String(repeating: "0", count: 12 - String(n).count) + String(n))!,
            householdId: household,
            cameraId: camera,
            type: type,
            startedAt: base.addingTimeInterval(-hoursAgo * 3600),
            feedback: feedback
        )
    }

    func testStartsEmptyWithoutAFirstPage() {
        let feed = TimelineFeed()
        XCTAssertTrue(feed.isEmpty)
        XCTAssertFalse(feed.hasMore)
        XCTAssertFalse(feed.hasLoadedFirstPage)
    }

    func testAppendKeepsOrderAndCursor() {
        var feed = TimelineFeed()
        feed.append(TimelinePage(events: [Self.event(1), Self.event(2, hoursAgo: 1)], nextCursor: "c1"))
        feed.append(TimelinePage(events: [Self.event(3, hoursAgo: 2)], nextCursor: nil))

        XCTAssertEqual(feed.events.map(\.id), [Self.event(1), Self.event(2), Self.event(3)].map(\.id))
        XCTAssertFalse(feed.hasMore)
        XCTAssertTrue(feed.hasLoadedFirstPage)
    }

    func testAppendSkipsDuplicatesAndTakesTheNewerCopy() {
        var feed = TimelineFeed()
        feed.append(TimelinePage(events: [Self.event(1), Self.event(2, hoursAgo: 1)], nextCursor: "c1"))
        feed.append(TimelinePage(events: [Self.event(2, hoursAgo: 1, feedback: .wrong), Self.event(3, hoursAgo: 2)], nextCursor: "c2"))

        XCTAssertEqual(feed.events.count, 3)
        XCTAssertEqual(feed.events[1].feedback, .wrong)
        XCTAssertTrue(feed.hasMore)
    }

    func testReplaceStartsOver() {
        var feed = TimelineFeed(events: [Self.event(1), Self.event(2)], nextCursor: "c1")
        feed.replace(with: TimelinePage(events: [Self.event(3)], nextCursor: nil))

        XCTAssertEqual(feed.events.map(\.id), [Self.event(3).id])
        XCTAssertFalse(feed.hasMore)
    }

    func testUpdateSwapsOnlyAKnownEvent() {
        var feed = TimelineFeed(events: [Self.event(1), Self.event(2)])
        feed.update(Self.event(2, feedback: .correct))
        feed.update(Self.event(9, feedback: .wrong))

        XCTAssertEqual(feed.event(id: Self.event(2).id)?.feedback, .correct)
        XCTAssertNil(feed.event(id: Self.event(9).id))
        XCTAssertEqual(feed.events.count, 2)
    }

    func testDaysGroupNewestFirst() {
        // 12:00, 03:00 on Nov 10; 23:00 on Nov 9; then an out-of-order 11:00 on Nov 10.
        let feed = TimelineFeed(events: [
            Self.event(1), Self.event(2, hoursAgo: 9), Self.event(3, hoursAgo: 13), Self.event(4, hoursAgo: 1),
        ])

        let days = feed.days(calendar: Self.utc)

        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].day, Date(timeIntervalSince1970: 1_794_268_800)) // 2026-11-10T00:00Z
        XCTAssertEqual(days[0].events.map(\.id), [1, 2, 4].map { Self.event($0).id })
        XCTAssertEqual(days[1].events.map(\.id), [Self.event(3).id])
    }

    func testOnlyDetectionsAcceptFeedback() {
        XCTAssertTrue(EventType.prolongedBarking.acceptsFeedback)
        XCTAssertTrue(EventType.atDoor.acceptsFeedback)
        XCTAssertFalse(EventType.cameraOffline.acceptsFeedback)
        XCTAssertFalse(EventType.dailySummary.acceptsFeedback)
    }

    func testTimelineFiltersListEveryTypeOnce() {
        XCTAssertEqual(Set(EventType.timelineFilters), Set(EventType.allCases))
        XCTAssertEqual(EventType.timelineFilters.count, EventType.allCases.count)
    }

    func testWithFeedbackChangesOnlyTheVerdict() {
        let original = EventDTO(
            id: Self.event(1).id, householdId: Self.household, cameraId: Self.camera, type: .whining,
            state: .whining, startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 90),
            confidence: 0.8, clipKey: "clips/a.mp4", snapshotKey: nil
        )

        let marked = original.with(feedback: .wrong)

        XCTAssertEqual(marked.feedback, .wrong)
        XCTAssertEqual(marked.with(feedback: nil), original)
        XCTAssertEqual(original.duration, 90)
        XCTAssertTrue(original.hasMedia)
    }

    func testDurationIsNilWhileOngoing() {
        XCTAssertNil(Self.event(1).duration)
        XCTAssertFalse(Self.event(1).hasMedia)
    }
}
