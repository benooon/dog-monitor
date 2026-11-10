import Foundation
import XCTest
@testable import DogMonitorCore

final class MotionDetectorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let size = 32

    /// A flat gray frame with an optional bright square at (x, y).
    private func frame(at seconds: TimeInterval, square: (x: Int, y: Int, side: Int)? = nil, base: UInt8 = 100) -> LumaFrame {
        var pixels = [UInt8](repeating: base, count: size * size)
        if let square {
            for y in square.y..<(square.y + square.side) {
                for x in square.x..<(square.x + square.side) {
                    pixels[y * size + x] = 220
                }
            }
        }
        return LumaFrame(width: size, height: size, pixels: pixels, timestamp: t0.addingTimeInterval(seconds))!
    }

    func testFirstFrameAndStillFramesHaveNoMotion() {
        var detector = MotionDetector()
        XCTAssertFalse(detector.process(frame(at: 0)).hasMotion)
        XCTAssertFalse(detector.process(frame(at: 0.5)).hasMotion)
        XCTAssertFalse(detector.isActive(at: t0.addingTimeInterval(0.5)))
    }

    func testSmallNoiseIsIgnored() {
        var detector = MotionDetector()
        _ = detector.process(frame(at: 0, base: 100))
        XCTAssertFalse(detector.process(frame(at: 0.5, base: 110)).hasMotion, "a 10-level shift is below the pixel threshold")
    }

    func testMovingObjectIsDetectedWithItsBox() throws {
        var detector = MotionDetector()
        _ = detector.process(frame(at: 0))
        let result = detector.process(frame(at: 0.5, square: (x: 8, y: 16, side: 8)))
        XCTAssertTrue(result.hasMotion)
        XCTAssertEqual(result.movingZones, ["frame"])
        XCTAssertEqual(try XCTUnwrap(result.zoneFractions["frame"]), 64.0 / 1024.0, accuracy: 1e-9)
        XCTAssertEqual(result.boundingBox, NormalizedRect(x: 0.25, y: 0.5, width: 0.25, height: 0.25))

        let detection = try XCTUnwrap(MotionDetector.detection(for: result))
        XCTAssertEqual(detection.kind, .motion)
        XCTAssertGreaterThan(detection.confidence, 0.5)
    }

    func testZonesOnlyReportTheirOwnMotion() {
        let left = MotionZone(id: "bed", rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 1))
        let right = MotionZone(id: "door", rect: NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1))
        var detector = MotionDetector(zones: [left, right])
        _ = detector.process(frame(at: 0))
        let result = detector.process(frame(at: 0.5, square: (x: 20, y: 4, side: 6)))
        XCTAssertEqual(result.movingZones, ["door"])
        XCTAssertEqual(result.zoneFractions["bed"], 0)
    }

    func testWholeFrameLightChangeIsNotMotion() {
        var detector = MotionDetector()
        _ = detector.process(frame(at: 0, base: 60))
        XCTAssertFalse(detector.process(frame(at: 0.5, base: 200)).hasMotion, "a lamp turning on changes everything")
    }

    func testGateStaysOpenForTheHoldTime() {
        var detector = MotionDetector()
        _ = detector.process(frame(at: 0))
        _ = detector.process(frame(at: 1, square: (x: 0, y: 0, side: 8)))
        XCTAssertTrue(detector.isActive(at: t0.addingTimeInterval(3.9)))
        XCTAssertFalse(detector.isActive(at: t0.addingTimeInterval(4)))
    }

    func testSamplesAtMostFourFramesPerSecond() {
        var detector = MotionDetector()
        XCTAssertTrue(detector.wants(t0))
        _ = detector.process(frame(at: 0))
        XCTAssertFalse(detector.wants(t0.addingTimeInterval(0.1)))
        XCTAssertTrue(detector.wants(t0.addingTimeInterval(0.25)))
    }

    func testDownsampleAveragesBlocksAndSkipsRowPadding() throws {
        // 4x2 image with 2 bytes of padding per row, downsampled by 2.
        let bytes: [UInt8] = [
            10, 30, 100, 100, 0, 0,
            10, 30, 100, 100, 0, 0,
        ]
        let small = try bytes.withUnsafeBufferPointer { plane in
            try XCTUnwrap(LumaFrame.downsample(plane, width: 4, height: 2, bytesPerRow: 6, targetWidth: 2, timestamp: t0))
        }
        XCTAssertEqual(small.width, 2)
        XCTAssertEqual(small.height, 1)
        XCTAssertEqual(small.pixels, [20, 100])
    }

    func testRejectsMismatchedBuffers() {
        XCTAssertNil(LumaFrame(width: 2, height: 2, pixels: [1, 2, 3], timestamp: t0))
        let bytes = [UInt8](repeating: 0, count: 4)
        let frame = bytes.withUnsafeBufferPointer {
            LumaFrame.downsample($0, width: 4, height: 4, bytesPerRow: 4, timestamp: t0)
        }
        XCTAssertNil(frame)
    }
}
