import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import DogMonitorCore

final class CameraZoneTests: XCTestCase {
    private let triangle = ZonePolygon(points: [
        NormalizedPoint(x: 0.1, y: 0.1), NormalizedPoint(x: 0.9, y: 0.1), NormalizedPoint(x: 0.5, y: 0.9),
    ])

    func testPointInPolygon() {
        XCTAssertTrue(triangle.contains(x: 0.5, y: 0.3))
        XCTAssertFalse(triangle.contains(x: 0.15, y: 0.8), "outside the slanted edge")
        XCTAssertFalse(triangle.contains(x: 0.5, y: 0.95))
        XCTAssertFalse(ZonePolygon(points: [NormalizedPoint(x: 0, y: 0), NormalizedPoint(x: 1, y: 1)]).contains(x: 0.5, y: 0.5))
    }

    func testConcavePolygon() {
        // An L shape: the notch at the top right is outside.
        let shape = ZonePolygon(points: [
            NormalizedPoint(x: 0, y: 0), NormalizedPoint(x: 0.5, y: 0), NormalizedPoint(x: 0.5, y: 0.5),
            NormalizedPoint(x: 1, y: 0.5), NormalizedPoint(x: 1, y: 1), NormalizedPoint(x: 0, y: 1),
        ])
        XCTAssertTrue(shape.contains(x: 0.25, y: 0.25))
        XCTAssertTrue(shape.contains(x: 0.75, y: 0.75))
        XCTAssertFalse(shape.contains(x: 0.75, y: 0.25))
    }

    func testPointsAreClampedAndValidityChecked() {
        XCTAssertEqual(NormalizedPoint(x: -0.2, y: 1.4), NormalizedPoint(x: 0, y: 1))
        XCTAssertTrue(triangle.isValid)
        XCTAssertFalse(ZonePolygon(points: Array(triangle.points.prefix(2))).isValid)
    }

    func testZonesSplitIntoDoorAndForbidden() {
        let zones = DogZones([
            CameraZone(kind: .door, polygon: triangle),
            CameraZone(kind: .forbidden, polygon: triangle),
            CameraZone(kind: .bed, polygon: triangle),
        ])
        XCTAssertEqual(zones.door.count, 1)
        XCTAssertEqual(zones.forbidden.count, 1)
    }

    func testSofaZonesAreOffLimits() {
        let zones = DogZones([
            CameraZone(kind: .sofa, polygon: triangle),
            CameraZone(kind: .forbidden, polygon: triangle),
        ])
        XCTAssertEqual(zones.forbidden.count, 2)
        XCTAssertEqual(CameraZone.Kind.allCases.filter(\.isOffLimits), [.sofa, .forbidden])
        XCTAssertEqual(CameraZone.Kind(rawValue: "sofa"), .sofa)
    }

    func testZonesAPIUsesBarePointArrays() async throws {
        let json = #"{"zones":[{"id":"\#(Fixtures.deviceID)","kind":"door","polygon":[{"x":0.1,"y":0.1},{"x":0.9,"y":0.1},{"x":0.5,"y":0.9}]}]}"#
        let stub = StubTransport(json: json)
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .device(id: UUID(), secret: "s"), transport: stub)

        let loaded = try await api.zones()
        XCTAssertEqual(loaded.first?.id, UUID(uuidString: Fixtures.deviceID))
        XCTAssertEqual(loaded.first?.polygon, triangle)
        XCTAssertEqual(stub.requests[0].url?.path, "/v1/device/zones")

        _ = try await api.replaceZones([CameraZone(kind: .forbidden, polygon: triangle)])
        let put = stub.requests[1]
        XCTAssertEqual(put.httpMethod, "PUT")
        let zones = try XCTUnwrap(Fixtures.bodyJSON(put)["zones"] as? [[String: Any]])
        XCTAssertEqual(zones.first?["kind"] as? String, "forbidden")
        XCTAssertNil(zones.first?["id"], "the server assigns ids")
        XCTAssertEqual((zones.first?["polygon"] as? [[String: Any]])?.count, 3)
    }
}
