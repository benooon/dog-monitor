import DogMonitorCore
import XCTest
@testable import DogMonitor

/// The simulator has no camera, so these cover the model's behavior before capture starts.
@MainActor
final class CameraModeModelTests: XCTestCase {
    func testStartsIdleWithPreviewHidden() {
        let model = CameraModeModel()
        XCTAssertEqual(model.status, .idle)
        XCTAssertFalse(model.isPreviewVisible)
        XCTAssertEqual(model.videoFPS, 0)
    }

    func testTapDoesNothingUntilRunning() {
        let model = CameraModeModel()
        model.tap()
        XCTAssertNil(model.screen.previewVisibleUntil)
        XCTAssertFalse(model.isPreviewVisible)
    }

    func testStopWhileIdleIsANoOp() {
        let model = CameraModeModel()
        model.stop()
        XCTAssertEqual(model.status, .idle)
    }

    func testCaptureServiceHandsOutIndependentStreams() {
        let service = CaptureService()
        let first = service.samples()
        let second = service.samples(bufferingNewest: 5)
        _ = (first, second)
        XCTAssertFalse(service.session.isRunning)
    }
}
