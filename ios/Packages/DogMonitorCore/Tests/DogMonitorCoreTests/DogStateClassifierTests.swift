import Foundation
import XCTest
@testable import DogMonitorCore

final class DogStateClassifierTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let door = NormalizedRect(x: 0.8, y: 0, width: 0.2, height: 1)
    private let sofa = NormalizedRect(x: 0, y: 0.6, width: 0.3, height: 0.4)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func dog(at seconds: TimeInterval, center: (x: Double, y: Double) = (0.5, 0.5), posture: Detection.Kind? = nil) -> [Detection] {
        let box = NormalizedRect(x: center.x - 0.05, y: center.y - 0.05, width: 0.1, height: 0.1)
        var detections = [Detection(kind: .dogVisible, confidence: 0.9, timestamp: at(seconds), boundingBox: box)]
        if let posture { detections.append(Detection(kind: posture, confidence: 0.8, timestamp: at(seconds), boundingBox: box)) }
        return detections
    }

    /// Feeds motion at 4 fps from `start` to `end`.
    private func motion(_ classifier: inout DogStateClassifier, _ moving: Bool, from start: TimeInterval, to end: TimeInterval) {
        var time = start
        while time < end {
            classifier.noteMotion(moving, at: at(time))
            time += 0.25
        }
    }

    func testNoDogIsNotVisible() {
        var classifier = DogStateClassifier()
        XCTAssertEqual(classifier.classify([], at: t0), .notVisible)
    }

    func testZonesWinAndForbiddenBeatsDoor() {
        var classifier = DogStateClassifier(zones: DogZones(door: [door], forbidden: [sofa]))
        XCTAssertEqual(classifier.classify(dog(at: 0, center: (0.9, 0.5)), at: t0), .atDoor)
        XCTAssertEqual(classifier.classify(dog(at: 1, center: (0.1, 0.8)), at: at(1)), .forbiddenZone)
        XCTAssertEqual(classifier.classify(dog(at: 2, center: (0.5, 0.5)), at: at(2)), .unknown)

        classifier.zones = DogZones(door: [sofa], forbidden: [sofa])
        XCTAssertEqual(classifier.classify(dog(at: 3, center: (0.1, 0.8)), at: at(3)), .forbiddenZone)
    }

    func testLyingStillForTwoMinutesIsResting() {
        var classifier = DogStateClassifier()
        motion(&classifier, false, from: 0, to: 130)
        XCTAssertEqual(classifier.classify(dog(at: 0, posture: .dogLying), at: t0), .unknown)
        XCTAssertEqual(classifier.classify(dog(at: 60, posture: .dogLying), at: at(60)), .unknown)
        XCTAssertEqual(classifier.classify(dog(at: 120, posture: .dogLying), at: at(120)), .resting)
    }

    func testGettingUpResetsTheRestingClock() {
        var classifier = DogStateClassifier()
        motion(&classifier, false, from: 0, to: 300)
        _ = classifier.classify(dog(at: 0, posture: .dogLying), at: t0)
        _ = classifier.classify(dog(at: 100, posture: .dogStanding), at: at(100))
        XCTAssertEqual(classifier.classify(dog(at: 130, posture: .dogLying), at: at(130)), .unknown)
        XCTAssertEqual(classifier.classify(dog(at: 250, posture: .dogLying), at: at(250)), .resting)
    }

    func testLeavingTheFrameResetsTheRestingClock() {
        var classifier = DogStateClassifier()
        motion(&classifier, false, from: 0, to: 200)
        _ = classifier.classify(dog(at: 0, posture: .dogLying), at: t0)
        XCTAssertEqual(classifier.classify([], at: at(60)), .notVisible)
        XCTAssertEqual(classifier.classify(dog(at: 130, posture: .dogLying), at: at(130)), .unknown)
    }

    func testContinuousMotionIsRestless() {
        var classifier = DogStateClassifier()
        motion(&classifier, true, from: 0, to: 30)
        XCTAssertEqual(classifier.classify(dog(at: 30, posture: .dogStanding), at: at(30)), .restless)
    }

    func testOccasionalMotionIsNotRestless() {
        var classifier = DogStateClassifier()
        var time = 0.0
        while time < 30 {
            classifier.noteMotion(Int(time * 4) % 4 == 0, at: at(time)) // one frame in four
            time += 0.25
        }
        XCTAssertEqual(classifier.classify(dog(at: 30), at: at(30)), .unknown)
    }

    func testMovingWhileLyingIsNeitherRestingNorRestless() {
        var classifier = DogStateClassifier()
        motion(&classifier, true, from: 0, to: 10)
        XCTAssertEqual(classifier.classify(dog(at: 10, posture: .dogLying), at: at(10)), .unknown)
        motion(&classifier, true, from: 10, to: 150)
        XCTAssertEqual(classifier.classify(dog(at: 150, posture: .dogLying), at: at(150)), .unknown)
    }

    func testOldMotionLeavesTheWindow() {
        var classifier = DogStateClassifier()
        motion(&classifier, true, from: 0, to: 30)
        motion(&classifier, false, from: 30, to: 70)
        XCTAssertEqual(classifier.classify(dog(at: 70, posture: .dogStanding), at: at(70)), .unknown)
    }
}
