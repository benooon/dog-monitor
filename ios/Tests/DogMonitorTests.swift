import DogMonitorCore
import XCTest
@testable import DogMonitor

final class DogMonitorTests: XCTestCase {
    func testEveryRoleHasASymbol() {
        for role in DeviceRole.allCases {
            XCTAssertFalse(role.systemImage.isEmpty, "\(role) has no symbol")
        }
    }

    func testRoleRawValuesAreStable() {
        // Stored in @AppStorage; changing these would reset every device's role.
        XCTAssertEqual(DeviceRole(rawValue: "camera"), .camera)
        XCTAssertEqual(DeviceRole(rawValue: "viewer"), .viewer)
    }
}
