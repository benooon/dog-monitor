import Foundation
import XCTest
@testable import DogMonitorCore

final class DogPoseTests: XCTestCase {
    private func joint(_ name: PoseJoint.Name, _ x: Double, _ y: Double, _ confidence: Double = 0.9) -> PoseJoint {
        PoseJoint(name: name, x: x, y: y, confidence: confidence)
    }

    func testStandingDogHasPawsWellBelowTheBody() {
        let joints = [
            joint(.neck, 0.3, 0.4), joint(.tailTop, 0.7, 0.42),
            joint(.leftFrontPaw, 0.32, 0.7), joint(.rightBackPaw, 0.68, 0.71),
        ]
        XCTAssertEqual(DogPosture.classify(joints), .standing)
        XCTAssertEqual(DogPosture.standing.detectionKind, .dogStanding)
    }

    func testLyingDogHasPawsNearTheBodyLine() {
        let joints = [
            joint(.neck, 0.3, 0.6), joint(.tailTop, 0.7, 0.62),
            joint(.leftFrontPaw, 0.2, 0.65), joint(.rightFrontPaw, 0.22, 0.66), joint(.leftBackPaw, 0.75, 0.68),
        ]
        XCTAssertEqual(DogPosture.classify(joints), .lying)
        XCTAssertEqual(DogPosture.lying.detectionKind, .dogLying)
    }

    func testNeedsBodyAndTwoConfidentPaws() {
        XCTAssertNil(DogPosture.classify([joint(.neck, 0.3, 0.4), joint(.leftFrontPaw, 0.3, 0.7)]))
        let lowConfidencePaws = [
            joint(.neck, 0.3, 0.4), joint(.tailTop, 0.7, 0.4),
            joint(.leftFrontPaw, 0.3, 0.7, 0.1), joint(.rightBackPaw, 0.7, 0.7, 0.2),
        ]
        XCTAssertNil(DogPosture.classify(lowConfidencePaws))
        XCTAssertNil(DogPosture.classify([joint(.neck, 0.5, 0.5), joint(.tailTop, 0.505, 0.5), joint(.leftFrontPaw, 0.5, 0.8), joint(.rightFrontPaw, 0.5, 0.8)]),
                     "a body this small can't be judged")
    }
}
