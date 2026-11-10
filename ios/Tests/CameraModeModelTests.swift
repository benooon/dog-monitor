import DogMonitorCore
import XCTest
@testable import DogMonitor

/// The simulator has no camera, so these cover the model's behavior before capture starts.
@MainActor
final class CameraModeModelTests: XCTestCase {
    func testStartsIdleWithPreviewHidden() {
        let model = CameraModeModel(credential: APICredential.none)
        XCTAssertEqual(model.status, .idle)
        XCTAssertFalse(model.isPreviewVisible)
        XCTAssertEqual(model.videoFPS, 0)
    }

    func testTapDoesNothingUntilRunning() {
        let model = CameraModeModel(credential: APICredential.none)
        model.tap()
        XCTAssertNil(model.screen.previewVisibleUntil)
        XCTAssertFalse(model.isPreviewVisible)
    }

    func testStopWhileIdleIsANoOp() {
        let model = CameraModeModel(credential: APICredential.none)
        model.stop()
        XCTAssertEqual(model.status, .idle)
    }

    func testPairingDecidesWhetherLiveViewRuns() {
        XCTAssertFalse(CameraModeModel(credential: APICredential.none).isPaired)
        XCTAssertFalse(CameraModeModel(credential: .user(token: "jwt")).isPaired)
        XCTAssertTrue(CameraModeModel(credential: .device(id: UUID(), secret: "s")).isPaired)
        XCTAssertNil(CameraModeModel(credential: .device(id: UUID(), secret: "s")).live, "live starts only with capture")
    }

    func testCaptureServiceHandsOutIndependentStreams() {
        let service = CaptureService()
        let first = service.samples(.video)
        let second = service.samples(.audio, bufferingNewest: 5)
        _ = (first, second)
        XCTAssertFalse(service.session.isRunning)
    }
}
