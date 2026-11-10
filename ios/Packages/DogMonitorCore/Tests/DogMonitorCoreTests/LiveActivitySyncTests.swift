import Foundation
import XCTest
@testable import DogMonitorCore

final class LiveActivitySyncTests: XCTestCase {
    private let front = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let back = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    func testNewDogStateUpdatesTheActivity() {
        let plan = LiveActivitySync.plan(
            showing: [front: CameraLiveActivityContent(state: .resting, online: true)],
            dogStates: [front: .barking],
            presence: [front: true],
            householdCameras: [front]
        )
        XCTAssertEqual(plan.updates, [front: CameraLiveActivityContent(state: .barking, online: true)])
        XCTAssertTrue(plan.ends.isEmpty)
    }

    func testGoingOfflineKeepsTheLastState() {
        let plan = LiveActivitySync.plan(
            showing: [front: CameraLiveActivityContent(state: .resting, online: true)],
            dogStates: [:],
            presence: [front: false],
            householdCameras: [front]
        )
        XCTAssertEqual(plan.updates, [front: CameraLiveActivityContent(state: .resting, online: false)])
    }

    func testNothingChangesWhenContentIsTheSame() {
        let plan = LiveActivitySync.plan(
            showing: [front: CameraLiveActivityContent(state: .resting, online: true)],
            dogStates: [front: .resting],
            presence: [front: true],
            householdCameras: [front, back]
        )
        XCTAssertTrue(plan.isEmpty)
    }

    func testMissingRealtimeDataKeepsCurrentContent() {
        let plan = LiveActivitySync.plan(
            showing: [front: CameraLiveActivityContent(state: nil, online: false)],
            dogStates: [back: .atDoor],
            presence: [back: true],
            householdCameras: [front, back]
        )
        XCTAssertTrue(plan.isEmpty)
    }

    func testUnpairedCameraEndsItsActivity() {
        let plan = LiveActivitySync.plan(
            showing: [
                front: CameraLiveActivityContent(state: .resting, online: true),
                back: CameraLiveActivityContent(state: .resting, online: true),
            ],
            dogStates: [front: .restless, back: .barking],
            presence: [:],
            householdCameras: [front]
        )
        XCTAssertEqual(plan.ends, [back])
        XCTAssertEqual(plan.updates, [front: CameraLiveActivityContent(state: .restless, online: true)])
    }

    func testUnloadedHouseholdEndsNothing() {
        let plan = LiveActivitySync.plan(
            showing: [front: CameraLiveActivityContent(state: .resting, online: true)],
            dogStates: [:],
            presence: [:],
            householdCameras: nil
        )
        XCTAssertTrue(plan.isEmpty)
    }

    func testNoActivitiesMeansAnEmptyPlan() {
        let plan = LiveActivitySync.plan(
            showing: [:],
            dogStates: [front: .barking],
            presence: [front: true],
            householdCameras: []
        )
        XCTAssertTrue(plan.isEmpty)
    }
}
