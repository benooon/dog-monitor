import Foundation
import XCTest
@testable import DogMonitorCore

final class BroadcasterTests: XCTestCase {
    func testEverySubscriberReceivesEveryElement() async {
        let broadcaster = Broadcaster<Int>()
        let a = broadcaster.subscribe(bufferingNewest: 10)
        let b = broadcaster.subscribe(bufferingNewest: 10)
        XCTAssertEqual(broadcaster.subscriberCount, 2)

        for i in 1...3 { broadcaster.yield(i) }
        broadcaster.finish()

        let receivedA = await collect(a)
        let receivedB = await collect(b)
        XCTAssertEqual(receivedA, [1, 2, 3])
        XCTAssertEqual(receivedB, [1, 2, 3])
    }

    func testSlowSubscriberKeepsOnlyNewest() async {
        let broadcaster = Broadcaster<Int>()
        let slow = broadcaster.subscribe(bufferingNewest: 2)
        for i in 1...5 { broadcaster.yield(i) }
        broadcaster.finish()
        let received = await collect(slow)
        XCTAssertEqual(received, [4, 5])
    }

    func testSubscriberOnlySeesElementsAfterSubscribing() async {
        let broadcaster = Broadcaster<String>()
        broadcaster.yield("before")
        let stream = broadcaster.subscribe(bufferingNewest: 5)
        broadcaster.yield("after")
        broadcaster.finish()
        let received = await collect(stream)
        XCTAssertEqual(received, ["after"])
    }

    func testCancelledConsumerIsRemoved() async {
        let broadcaster = Broadcaster<Int>()
        let stream = broadcaster.subscribe()
        let task = Task {
            for await _ in stream {}
        }
        task.cancel()
        await task.value
        XCTAssertEqual(broadcaster.subscriberCount, 0)
        broadcaster.yield(1) // must not crash or deliver anywhere
    }

    func testSubscribingAfterFinishGivesFinishedStream() async {
        let broadcaster = Broadcaster<Int>()
        broadcaster.finish()
        let stream = broadcaster.subscribe()
        broadcaster.yield(1)
        let received = await collect(stream)
        XCTAssertEqual(received, [])
        XCTAssertEqual(broadcaster.subscriberCount, 0)
    }

    func testConcurrentYieldsFromManyThreads() async {
        let broadcaster = Broadcaster<Int>()
        let stream = broadcaster.subscribe(bufferingNewest: 10_000)
        DispatchQueue.concurrentPerform(iterations: 1_000) { broadcaster.yield($0) }
        broadcaster.finish()
        let received = await collect(stream)
        XCTAssertEqual(Set(received), Set(0..<1_000))
    }

    private func collect<T: Sendable>(_ stream: AsyncStream<T>) async -> [T] {
        var result: [T] = []
        for await element in stream { result.append(element) }
        return result
    }
}

final class CameraScreenStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testStartsBlackAndDimmed() {
        let state = CameraScreenState()
        XCTAssertFalse(state.isPreviewVisible(at: t0))
        XCTAssertEqual(state.screenBrightness(at: t0), 0)
    }

    func testTapShowsPreviewThenItTimesOut() {
        var state = CameraScreenState(previewTimeout: 10)
        state.tap(at: t0)
        XCTAssertTrue(state.isPreviewVisible(at: t0))
        XCTAssertNil(state.screenBrightness(at: t0))
        XCTAssertTrue(state.isPreviewVisible(at: t0 + 9.9))
        XCTAssertFalse(state.isPreviewVisible(at: t0 + 10))
        XCTAssertEqual(state.screenBrightness(at: t0 + 10), 0)
    }

    func testSecondTapHidesPreview() {
        var state = CameraScreenState()
        state.tap(at: t0)
        state.tap(at: t0 + 1)
        XCTAssertFalse(state.isPreviewVisible(at: t0 + 1))
    }

    func testTapAfterTimeoutShowsAgain() {
        var state = CameraScreenState(previewTimeout: 5)
        state.tap(at: t0)
        state.tap(at: t0 + 6)
        XCTAssertTrue(state.isPreviewVisible(at: t0 + 6))
    }

    func testKeepAliveExtendsOnlyAVisiblePreview() {
        var state = CameraScreenState(previewTimeout: 5)
        state.keepAlive(at: t0)
        XCTAssertFalse(state.isPreviewVisible(at: t0))

        state.tap(at: t0)
        state.keepAlive(at: t0 + 4)
        XCTAssertTrue(state.isPreviewVisible(at: t0 + 8))
        XCTAssertFalse(state.isPreviewVisible(at: t0 + 9))
    }

    func testHidePreview() {
        var state = CameraScreenState()
        state.tap(at: t0)
        state.hidePreview()
        XCTAssertFalse(state.isPreviewVisible(at: t0))
    }

    func testTimeoutHasAFloor() {
        XCTAssertEqual(CameraScreenState(previewTimeout: 0).previewTimeout, 1)
    }
}

final class FrameRateMeterTests: XCTestCase {
    func testZeroWithTooFewFrames() {
        var meter = FrameRateMeter()
        XCTAssertEqual(meter.framesPerSecond, 0)
        meter.record(1)
        XCTAssertEqual(meter.framesPerSecond, 0)
    }

    func testSteadyThirtyFPS() {
        var meter = FrameRateMeter(window: 2)
        for i in 0..<90 { meter.record(Double(i) / 30) }
        XCTAssertEqual(meter.framesPerSecond, 30, accuracy: 0.01)
    }

    func testOldFramesLeaveTheWindow() {
        var meter = FrameRateMeter(window: 1)
        for i in 0..<30 { meter.record(Double(i) / 30) }   // 30 fps for 1 s
        for i in 0..<10 { meter.record(1 + Double(i + 1) / 5) } // then 5 fps for 2 s
        XCTAssertEqual(meter.framesPerSecond, 5, accuracy: 0.01)
    }

    func testClockResetStartsFresh() {
        var meter = FrameRateMeter()
        for i in 0..<10 { meter.record(100 + Double(i) / 10) }
        meter.record(0)
        XCTAssertEqual(meter.framesPerSecond, 0)
        meter.record(0.5)
        XCTAssertEqual(meter.framesPerSecond, 2, accuracy: 0.01)
    }
}
