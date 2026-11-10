import Foundation
import XCTest
@testable import DogMonitorCore

final class HealthMonitorTests: XCTestCase {
    private let camera = UUID(uuidString: "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d")!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func health(
        at seconds: TimeInterval,
        battery: Double? = 0.8,
        charging: Bool = true,
        thermal: CameraHealth.ThermalState = .nominal
    ) -> CameraHealth {
        CameraHealth(
            batteryLevel: battery,
            isCharging: charging,
            thermalState: thermal,
            network: .wifi,
            reportedAt: t0.addingTimeInterval(seconds)
        )
    }

    private func makeMonitor() -> HealthMonitor {
        HealthMonitor(cameraID: camera)
    }

    func testHealthyPhoneStaysQuiet() {
        var monitor = makeMonitor()
        XCTAssertEqual(monitor.update(health(at: 0)), [])
        XCTAssertEqual(monitor.update(health(at: 600)), [])
        XCTAssertEqual(monitor.screenWarnings, [])
        XCTAssertEqual(monitor.targetFrameRate, 30)
    }

    func testShortUnplugOnlyWarnsOnScreen() {
        var monitor = makeMonitor()
        XCTAssertEqual(monitor.update(health(at: 0, charging: false)), [])
        XCTAssertEqual(monitor.screenWarnings, [.unplugged])
        XCTAssertEqual(monitor.update(health(at: 60, charging: false)), [])
        XCTAssertEqual(monitor.update(health(at: 90, charging: true)), [])
        XCTAssertEqual(monitor.screenWarnings, [])
    }

    func testLongUnplugStartsAndChargingEndsTheEvent() throws {
        var monitor = makeMonitor()
        _ = monitor.update(health(at: 0, charging: false))
        let started = monitor.update(health(at: 120, charging: false))
        XCTAssertEqual(started.count, 1)
        guard case .started(let event) = try XCTUnwrap(started.first) else { return XCTFail("expected start") }
        XCTAssertEqual(event.type, .lowBattery)
        XCTAssertEqual(event.cameraID, camera)
        XCTAssertNil(event.state)
        XCTAssertEqual(event.startedAt, t0.addingTimeInterval(120))

        XCTAssertEqual(monitor.update(health(at: 300, charging: false)), [], "no repeat while unplugged")

        let ended = monitor.update(health(at: 400, charging: true))
        guard case .ended(let done) = try XCTUnwrap(ended.first) else { return XCTFail("expected end") }
        XCTAssertEqual(done.id, event.id)
        XCTAssertEqual(done.endedAt, t0.addingTimeInterval(400))
    }

    func testLowBatteryOffChargerAlertsRightAway() throws {
        var monitor = makeMonitor()
        let outputs = monitor.update(health(at: 0, battery: 0.15, charging: false))
        guard case .started(let event) = try XCTUnwrap(outputs.first) else { return XCTFail("expected start") }
        XCTAssertEqual(event.type, .lowBattery)
        XCTAssertEqual(monitor.screenWarnings, [.lowBattery], "low battery replaces the unplugged warning")
    }

    func testLowBatteryWhileChargingIsFine() {
        var monitor = makeMonitor()
        XCTAssertEqual(monitor.update(health(at: 0, battery: 0.1, charging: true)), [])
        XCTAssertEqual(monitor.screenWarnings, [])
    }

    func testUnknownBatteryNeverReportsPower() {
        var monitor = makeMonitor()
        XCTAssertEqual(monitor.update(health(at: 0, battery: nil, charging: false)), [])
        XCTAssertEqual(monitor.update(health(at: 1000, battery: nil, charging: false)), [])
        XCTAssertEqual(monitor.screenWarnings, [])
    }

    func testHeatLowersFrameRateAndAlertsAfterAWhile() throws {
        var monitor = makeMonitor()
        XCTAssertEqual(monitor.update(health(at: 0, thermal: .fair)), [])
        XCTAssertEqual(monitor.targetFrameRate, 30)

        XCTAssertEqual(monitor.update(health(at: 10, thermal: .serious)), [])
        XCTAssertEqual(monitor.targetFrameRate, 15)
        XCTAssertEqual(monitor.screenWarnings, [.overheating])

        let started = monitor.update(health(at: 40, thermal: .critical))
        guard case .started(let event) = try XCTUnwrap(started.first) else { return XCTFail("expected start") }
        XCTAssertEqual(event.type, .overheating)
        XCTAssertEqual(monitor.targetFrameRate, 10)

        let ended = monitor.update(health(at: 100, thermal: .fair))
        guard case .ended(let done) = try XCTUnwrap(ended.first) else { return XCTFail("expected end") }
        XCTAssertEqual(done.id, event.id)
        XCTAssertEqual(monitor.targetFrameRate, 30)
        XCTAssertEqual(monitor.screenWarnings, [])
    }

    func testBriefHeatSpikeDoesNotAlert() {
        var monitor = makeMonitor()
        XCTAssertEqual(monitor.update(health(at: 0, thermal: .serious)), [])
        XCTAssertEqual(monitor.update(health(at: 20, thermal: .fair)), [])
        XCTAssertEqual(monitor.update(health(at: 45, thermal: .serious)), [], "the timer restarts")
    }

    func testHotAndUnpluggedWarningsAreOrderedByImportance() {
        var monitor = makeMonitor()
        _ = monitor.update(health(at: 0, charging: false, thermal: .serious))
        XCTAssertEqual(monitor.screenWarnings, [.overheating, .unplugged])
    }
}
