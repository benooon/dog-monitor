import DogMonitorCore
import XCTest
@testable import DogMonitor

final class ZoneTests: XCTestCase {
    func testCachedZonesRoundTrip() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ZoneTests-\(UUID().uuidString)"))
        XCTAssertEqual(CameraModeModel.cachedZones(defaults: defaults), [])
        let zone = CameraZone(kind: .door, polygon: ZonePolygon(rect: NormalizedRect(x: 0.8, y: 0, width: 0.2, height: 1)))
        defaults.set(try JSONEncoder().encode([zone]), forKey: CameraModeModel.zonesKey)
        let cached = CameraModeModel.cachedZones(defaults: defaults)
        XCTAssertEqual(cached.map(\.kind), [.door])
        XCTAssertEqual(cached.first?.polygon, zone.polygon)
    }

    @MainActor
    func testSnapshotIsNilWhileTheCameraIsOff() async {
        let model = CameraModeModel(credential: APICredential.none)
        let image = await model.snapshot()
        XCTAssertNil(image)
    }
}
