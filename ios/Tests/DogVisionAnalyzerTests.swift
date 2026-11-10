import XCTest
@testable import DogMonitor

final class DogVisionAnalyzerTests: XCTestCase {
    func testLooksOftenWithMotionAndRarelyWithout() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(DogVisionAnalyzer.isDue(lastRun: nil, now: t0, motion: false))
        XCTAssertTrue(DogVisionAnalyzer.isDue(lastRun: t0, now: t0.addingTimeInterval(0.5), motion: true))
        XCTAssertFalse(DogVisionAnalyzer.isDue(lastRun: t0, now: t0.addingTimeInterval(0.5), motion: false))
        XCTAssertTrue(DogVisionAnalyzer.isDue(lastRun: t0, now: t0.addingTimeInterval(10), motion: false))
    }
}
