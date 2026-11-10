import XCTest
@testable import DogMonitor

@MainActor
final class DurationFormattingTests: XCTestCase {
    /// Timeline durations follow the screen's locale, not the device's.
    func testTimelineDurationFollowsLocale() throws {
        let english = try XCTUnwrap(TimelineRow.formatted(duration: 180, locale: Locale(identifier: "en_US")))
        let hebrew = try XCTUnwrap(TimelineRow.formatted(duration: 180, locale: Locale(identifier: "he_IL")))
        XCTAssertTrue(english.contains("min"), english)
        XCTAssertFalse(hebrew.contains("min"), hebrew)
        XCTAssertTrue(hebrew.contains("3"), hebrew)
    }

    func testTimelineDurationHidesUnderOneSecond() {
        XCTAssertNil(TimelineRow.formatted(duration: 0.4, locale: Locale(identifier: "en_US")))
    }
}
