import XCTest
@testable import DogMonitorCore

final class LiveDecryptionWatchTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testNothingRecordedIsNotWrong() {
        XCTAssertFalse(LiveDecryptionWatch().isWrongKey(at: t0.addingTimeInterval(60)))
    }

    func testShortFailureIsNotWrong() {
        var watch = LiveDecryptionWatch(grace: 4)
        watch.record(.failing, at: t0)
        XCTAssertFalse(watch.isWrongKey(at: t0.addingTimeInterval(3)))
    }

    func testFailureThatLastsIsWrong() {
        var watch = LiveDecryptionWatch(grace: 4)
        watch.record(.failing, at: t0)
        watch.record(.failing, at: t0.addingTimeInterval(2))
        XCTAssertTrue(watch.isWrongKey(at: t0.addingTimeInterval(4)))
    }

    func testDecryptedFrameClearsTheFailure() {
        var watch = LiveDecryptionWatch(grace: 4)
        watch.record(.failing, at: t0)
        watch.record(.ok, at: t0.addingTimeInterval(1))
        XCTAssertFalse(watch.isWrongKey(at: t0.addingTimeInterval(10)))
        XCTAssertTrue(watch.keyWorked)
    }

    func testNeutralStatesChangeNothing() {
        var watch = LiveDecryptionWatch(grace: 4)
        watch.record(.failing, at: t0)
        watch.record(.neutral, at: t0.addingTimeInterval(1))
        XCTAssertTrue(watch.isWrongKey(at: t0.addingTimeInterval(5)))
        XCTAssertFalse(watch.keyWorked)
    }
}
