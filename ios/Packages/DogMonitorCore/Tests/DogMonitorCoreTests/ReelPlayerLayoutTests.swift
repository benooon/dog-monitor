import XCTest
@testable import DogMonitorCore

final class ReelPlayerLayoutTests: XCTestCase {
    func testCapsTallPlayerAtSixtyPercentOfTheScreen() {
        // iPhone-ish: a 361 pt row would want a 642 pt tall player; 60% of 800 is 480.
        let size = ReelPlayerLayout.size(availableWidth: 361, containerHeight: 800)
        XCTAssertEqual(size.height, 480, accuracy: 0.001)
        XCTAssertEqual(size.width, 270, accuracy: 0.001)
    }

    func testFillsTheRowWhenItFits() {
        let size = ReelPlayerLayout.size(availableWidth: 180, containerHeight: 1000)
        XCTAssertEqual(size.width, 180, accuracy: 0.001)
        XCTAssertEqual(size.height, 320, accuracy: 0.001)
    }

    func testKeepsNineBySixteen() {
        let size = ReelPlayerLayout.size(availableWidth: 700, containerHeight: 1100)
        XCTAssertEqual(size.width / size.height, 9.0 / 16.0, accuracy: 0.0001)
    }

    func testNoCapWhenContainerUnknown() {
        let size = ReelPlayerLayout.size(availableWidth: 360, containerHeight: 0)
        XCTAssertEqual(size.width, 360, accuracy: 0.001)
        XCTAssertEqual(size.height, 640, accuracy: 0.001)
    }

    func testZeroBeforeMeasured() {
        XCTAssertEqual(
            ReelPlayerLayout.size(availableWidth: 0, containerHeight: 800),
            ReelPlayerLayout.Size(width: 0, height: 0)
        )
    }
}
