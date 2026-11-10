import Foundation
import XCTest
@testable import DogMonitorCore

final class DogStatusSnapshotTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_794_312_000)

    private static func snapshot(
        _ n: Int, state: DogState? = .resting, online: Bool = true, minutesAgo: Double = 1
    ) -> DogStatusSnapshot {
        DogStatusSnapshot(
            cameraId: UUID(uuidString: "00000000-0000-4000-8000-00000000000\(n)")!,
            cameraName: "Camera \(n)", dogName: "Rex", state: state, online: online,
            updatedAt: now.addingTimeInterval(-minutesAgo * 60)
        )
    }

    func testFreshOnlineSnapshotShowsItsState() {
        XCTAssertEqual(Self.snapshot(1, state: .barking).displayState(at: Self.now), .barking)
    }

    func testOfflineStaleOrUnknownReadsAsUnknown() {
        XCTAssertEqual(Self.snapshot(1, online: false).displayState(at: Self.now), .unknown)
        XCTAssertEqual(Self.snapshot(1, minutesAgo: 31).displayState(at: Self.now), .unknown)
        XCTAssertEqual(Self.snapshot(1, state: nil).displayState(at: Self.now), .unknown)
        XCTAssertFalse(Self.snapshot(1, minutesAgo: 30).isStale(at: Self.now))
    }

    func testFeaturedPrefersACameraWithSomethingToSay() {
        let offline = Self.snapshot(1, online: false)
        let quiet = Self.snapshot(2, state: nil)
        let watching = Self.snapshot(3)

        XCTAssertEqual(DogStatusSnapshot.featured(in: [offline, quiet, watching]), watching)
        XCTAssertEqual(DogStatusSnapshot.featured(in: [offline, quiet]), offline)
        XCTAssertNil(DogStatusSnapshot.featured(in: []))
    }

    func testRoundTripsAndToleratesGarbage() throws {
        let snapshots = [Self.snapshot(1), Self.snapshot(2, state: nil, online: false)]

        let data = try DogStatusSnapshot.encode(snapshots)

        XCTAssertEqual(DogStatusSnapshot.decode(data), snapshots)
        XCTAssertEqual(DogStatusSnapshot.decode(Data("not json".utf8)), [])
        XCTAssertEqual(DogStatusSnapshot.decode(nil), [])
    }
}
