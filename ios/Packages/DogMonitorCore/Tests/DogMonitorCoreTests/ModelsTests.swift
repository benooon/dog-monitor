import Foundation
import XCTest
@testable import DogMonitorCore

final class ModelsTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(T.self, from: encoder.encode(value))
        XCTAssertEqual(decoded, value, file: file, line: line)
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testVersion() {
        XCTAssertFalse(DogMonitorCore.version.isEmpty)
    }

    func testEventTypeDefaultsMatchSpec() {
        XCTAssertTrue(EventType.prolongedBarking.isEnabledByDefault)
        XCTAssertFalse(EventType.forbiddenZone.isEnabledByDefault)
        XCTAssertFalse(EventType.atDoor.isEnabledByDefault)
        XCTAssertFalse(EventType.notVisible.isEnabledByDefault)
        XCTAssertEqual(EventType.whining.interruptionLevel, .timeSensitive)
        XCTAssertEqual(EventType.atDoor.interruptionLevel, .active)
        XCTAssertEqual(EventType.dailySummary.interruptionLevel, .passive)
        XCTAssertEqual(EventType.prolongedBarking.dogState, .barking)
        XCTAssertNil(EventType.cameraOffline.dogState)
    }

    func testEventTypeWireFormat() throws {
        let data = try JSONEncoder().encode([EventType.prolongedBarking])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["prolongedBarking"]"#)
    }

    func testDogStateAlerting() {
        XCTAssertTrue(DogState.barking.isAlerting)
        XCTAssertFalse(DogState.resting.isAlerting)
        XCTAssertFalse(DogState.unknown.isAlerting)
    }

    func testDetectionClampsConfidenceAndThreshold() throws {
        let d = Detection(kind: .bark, confidence: 1.4, timestamp: t0)
        XCTAssertEqual(d.confidence, 1)
        XCTAssertTrue(d.kind.isAudio)
        XCTAssertFalse(Detection.Kind.dogVisible.isAudio)
        XCTAssertFalse(Detection(kind: .bark, confidence: 0.69, timestamp: t0).meets(threshold: Detection.defaultAudioConfidenceThreshold))
        XCTAssertTrue(Detection(kind: .bark, confidence: 0.7, timestamp: t0).meets(threshold: Detection.defaultAudioConfidenceThreshold))
        try roundTrip(Detection(kind: .dogVisible, confidence: 0.9, timestamp: t0,
                                boundingBox: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)))
    }

    func testDogEventDerivesStateAndDuration() throws {
        let event = DogEvent(cameraID: UUID(), type: .prolongedBarking, startedAt: t0, confidence: 0.85)
        XCTAssertEqual(event.state, .barking)
        XCTAssertTrue(event.isOngoing)
        XCTAssertEqual(event.duration(now: t0.addingTimeInterval(120)), 120, accuracy: 0.001)
        var ended = event
        ended.endedAt = t0.addingTimeInterval(30)
        XCTAssertEqual(ended.duration(now: t0.addingTimeInterval(999)), 30, accuracy: 0.001)
        try roundTrip(ended)
    }

    func testCameraHealthWarnings() throws {
        let healthy = CameraHealth(batteryLevel: 0.9, isCharging: true, thermalState: .fair, network: .wifi, reportedAt: t0)
        XCTAssertTrue(healthy.warnings.isEmpty)
        let bad = CameraHealth(batteryLevel: 0.1, isCharging: false, thermalState: .serious, network: .none, reportedAt: t0)
        XCTAssertEqual(bad.warnings, [.unplugged, .lowBattery, .overheating, .offline])
        XCTAssertTrue(CameraHealth.ThermalState.critical > .serious)
        try roundTrip(bad)
    }
}

final class DeviceRoleTests: XCTestCase {
    func testWireFormat() throws {
        let data = try JSONEncoder().encode([DeviceRole.camera, .viewer])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["camera","viewer"]"#)
    }

    func testDeviceInitDefaultsAndRoundTrip() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let camera = DeviceDTO(
            id: UUID(),
            householdId: UUID(),
            name: "Living room",
            role: .camera,
            lastHeartbeatAt: t0.addingTimeInterval(-60),
            dogState: DogState.resting.rawValue,
            createdAt: t0
        )
        XCTAssertEqual(camera.status, .active)
        XCTAssertFalse(camera.hasPushToken)
        XCTAssertNil(camera.userId)
        XCTAssertEqual(camera.currentDogState, .resting)
        XCTAssertTrue(camera.isOnline(now: t0))
        XCTAssertFalse(camera.isOnline(now: t0.addingTimeInterval(DeviceDTO.offlineAfter)))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(DeviceDTO.self, from: encoder.encode(camera)), camera)
    }

    func testHouseholdInitKeepsOnlyActiveCameras() {
        let household = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func device(_ role: DeviceRole, _ status: DeviceStatus = .active) -> DeviceDTO {
            DeviceDTO(id: UUID(), householdId: household, name: "Phone", role: role, status: status, createdAt: now)
        }
        let dto = HouseholdDTO(
            id: household,
            name: "Home",
            ownerId: UUID(),
            role: .owner,
            dogs: [DogDTO(id: UUID(), householdId: household, name: "Rex", createdAt: now)],
            devices: [device(.camera), device(.camera, .revoked), device(.viewer)]
        )
        XCTAssertEqual(dto.plan, "free")
        XCTAssertEqual(dto.cameras.count, 1)
        XCTAssertEqual(dto.dogs.first?.name, "Rex")
        XCTAssertNil(dto.dogs.first?.photoKey)
    }
}
