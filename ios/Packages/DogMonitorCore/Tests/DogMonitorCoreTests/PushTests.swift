import Foundation
import XCTest
@testable import DogMonitorCore

final class PushPayloadTests: XCTestCase {
    func testParsesEventPushes() {
        let payload = PushPayload(userInfo: [
            "aps": ["alert": ["title": "Living room"]],
            "eventId": "22222222-2222-4222-8222-222222222222",
            "cameraId": "11111111-1111-4111-8111-111111111111",
            "type": "prolongedBarking",
            "snapshotKey": "snaps/1.jpg",
        ])
        XCTAssertEqual(payload, PushPayload(
            eventId: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            cameraId: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            type: .prolongedBarking,
            snapshotKey: "snaps/1.jpg"
        ))
    }

    func testToleratesUnknownTypesAndRejectsOtherPushes() {
        let future = PushPayload(userInfo: [
            "eventId": "22222222-2222-4222-8222-222222222222",
            "cameraId": "11111111-1111-4111-8111-111111111111",
            "type": "somethingNew",
        ])
        XCTAssertNotNil(future)
        XCTAssertNil(future?.type)
        XCTAssertNil(PushPayload(userInfo: ["aps": [String: Any]()]))
        XCTAssertNil(PushPayload(userInfo: ["eventId": "x", "cameraId": "y"]))
    }

    func testActionIdentifiersAreStable() {
        XCTAssertEqual(PushPayload.category, "DOG_EVENT")
        XCTAssertEqual(PushPayload.Action.allCases.map(\.rawValue), ["WATCH_LIVE", "MUTE_1H"])
    }

    func testTokenHex() {
        XCTAssertEqual(PushToken.hex(Data([0x00, 0xab, 0x10, 0xff])), "00ab10ff")
    }

    func testMuteLastsAnHour() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(PushMute.until(from: now), Date(timeIntervalSince1970: 3600))
    }
}
