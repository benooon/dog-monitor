import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import DogMonitorCore

final class NotificationSettingsTests: XCTestCase {
    private let kitchen = UUID(uuidString: "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d")!
    private let hall = UUID(uuidString: "0f9e8d7c-6b5a-4f3e-8d2c-1b0a99887766")!

    private static let types: [NotificationTypeInfoDTO] = EventType.allCases.map { type in
        NotificationTypeInfoDTO(
            eventType: type,
            enabledByDefault: type.isEnabledByDefault,
            bypassesQuietHours: type.interruptionLevel == .timeSensitive
        )
    }

    private func settings(_ prefs: [NotificationPrefDTO] = []) -> NotificationSettings {
        NotificationSettings(NotificationPrefsDTO(types: Self.types, prefs: prefs))
    }

    // MARK: - Time of day

    func testTimeOfDayParsesAndFormats() {
        XCTAssertEqual(TimeOfDay("07:05")?.wireValue, "07:05")
        XCTAssertEqual(TimeOfDay("22:30:00")?.minutesSinceMidnight, 22 * 60 + 30)
        XCTAssertNil(TimeOfDay("24:00"))
        XCTAssertNil(TimeOfDay("7:00"))
        XCTAssertNil(TimeOfDay("ab:cd"))
        XCTAssertNil(TimeOfDay(hour: 3, minute: 60))
    }

    func testQuietHoursWrapMidnightLikeTheBackend() throws {
        let night = QuietHours.suggested
        XCTAssertTrue(night.contains(try XCTUnwrap(TimeOfDay("23:00"))))
        XCTAssertTrue(night.contains(try XCTUnwrap(TimeOfDay("06:59"))))
        XCTAssertFalse(night.contains(try XCTUnwrap(TimeOfDay("07:00"))))
        XCTAssertFalse(night.contains(try XCTUnwrap(TimeOfDay("12:00"))))

        let nap = QuietHours(start: try XCTUnwrap(TimeOfDay("13:00")), end: try XCTUnwrap(TimeOfDay("15:00")))
        XCTAssertTrue(nap.contains(try XCTUnwrap(TimeOfDay("13:00"))))
        XCTAssertFalse(nap.contains(try XCTUnwrap(TimeOfDay("15:00"))))

        let empty = QuietHours(start: nap.start, end: nap.start)
        XCTAssertFalse(empty.contains(nap.start))
    }

    // MARK: - Reading

    func testWithoutRowsEverythingFollowsTheDefaults() {
        let s = settings()
        for type in EventType.allCases {
            XCTAssertEqual(s.isEnabled(type), type.isEnabledByDefault, "\(type)")
            XCTAssertEqual(s.isEnabled(type, camera: kitchen), type.isEnabledByDefault, "\(type)")
        }
        XCTAssertNil(s.quietHours)
        XCTAssertTrue(s.bypassesQuietHours(.prolongedBarking))
        XCTAssertFalse(s.bypassesQuietHours(.dailySummary))
    }

    func testLoadsHouseholdRowsCameraRowsAndQuietHours() {
        let s = settings([
            NotificationPrefDTO(cameraId: nil, eventType: .calmedDown, enabled: false, quietStart: "22:00", quietEnd: "07:00"),
            NotificationPrefDTO(cameraId: kitchen, eventType: .atDoor, enabled: true),
        ])
        XCTAssertFalse(s.isEnabled(.calmedDown))
        XCTAssertFalse(s.isEnabled(.atDoor))
        XCTAssertTrue(s.isEnabled(.atDoor, camera: kitchen))
        XCTAssertFalse(s.isEnabled(.atDoor, camera: hall))
        XCTAssertEqual(s.overriddenTypes(camera: kitchen), [.atDoor])
        XCTAssertEqual(s.quietHours, QuietHours.suggested)
    }

    func testEveryTypeBelongsToExactlyOneGroup() {
        let grouped = NotificationSettings.Group.allCases.flatMap(\.eventTypes)
        XCTAssertEqual(grouped.sorted { $0.rawValue < $1.rawValue }, EventType.allCases.sorted { $0.rawValue < $1.rawValue })
        XCTAssertEqual(NotificationSettings.Group.camera.eventTypes, [.cameraOffline, .lowBattery, .overheating])
    }

    // MARK: - Editing

    func testCameraChoiceIsOnlyKeptWhileItDiffers() {
        var s = settings()
        s.setEnabled(false, for: .prolongedBarking, camera: kitchen)
        XCTAssertEqual(s.overriddenTypes(camera: kitchen), [.prolongedBarking])

        s.setEnabled(true, for: .prolongedBarking, camera: kitchen)
        XCTAssertEqual(s.overriddenTypes(camera: kitchen), [])
        XCTAssertTrue(s.isEnabled(.prolongedBarking, camera: kitchen))
    }

    func testCameraChoiceSurvivesHouseholdChanges() {
        var s = settings()
        s.setEnabled(false, for: .whining, camera: kitchen)
        s.setEnabled(false, for: .whining)
        XCTAssertFalse(s.isEnabled(.whining, camera: kitchen))
        XCTAssertFalse(s.isEnabled(.whining, camera: hall))
        XCTAssertEqual(s.overriddenTypes(camera: kitchen), [], "matching the household is not a difference")
    }

    func testResetAndPruneCameras() {
        var s = settings()
        s.setEnabled(true, for: .atDoor, camera: kitchen)
        s.setEnabled(true, for: .atDoor, camera: hall)
        s.keepOverrides(forCameras: [hall])
        XCTAssertFalse(s.isEnabled(.atDoor, camera: kitchen))
        XCTAssertTrue(s.isEnabled(.atDoor, camera: hall))
        s.resetOverrides(camera: hall)
        XCTAssertFalse(s.isEnabled(.atDoor, camera: hall))
    }

    // MARK: - Saving

    func testRequestHasAHouseholdRowPerTypeAndOnlyDifferingCameraRows() {
        var s = settings()
        s.setEnabled(false, for: .dailySummary)
        s.setEnabled(true, for: .forbiddenZone, camera: kitchen)
        s.setEnabled(false, for: .forbiddenZone, camera: hall) // same as household: not stored

        let rows = s.requestPrefs()
        let household = rows.filter { $0.cameraId == nil }
        XCTAssertEqual(household.map(\.eventType), EventType.allCases)
        XCTAssertEqual(household.first { $0.eventType == .dailySummary }?.enabled, false)

        let cameraRows = rows.filter { $0.cameraId != nil }
        XCTAssertEqual(cameraRows, [NotificationPrefDTO(cameraId: kitchen, eventType: .forbiddenZone, enabled: true)])
    }

    func testQuietHoursRideOnlyOnTypesTheyCanHoldBack() throws {
        var s = settings()
        s.quietHours = QuietHours(start: try XCTUnwrap(TimeOfDay("21:30")), end: try XCTUnwrap(TimeOfDay("06:45")))
        s.setEnabled(true, for: .atDoor, camera: kitchen)

        for row in s.requestPrefs() {
            if s.bypassesQuietHours(row.eventType) {
                XCTAssertNil(row.quietStart, "\(row.eventType)")
                XCTAssertNil(row.quietEnd, "\(row.eventType)")
            } else {
                XCTAssertEqual(row.quietStart, "21:30", "\(row.eventType)")
                XCTAssertEqual(row.quietEnd, "06:45", "\(row.eventType)")
            }
        }
        XCTAssertEqual(s.requestPrefs().last?.quietStart, "21:30", "camera rows carry the window too")
    }

    func testSavedRowsLoadBackToTheSameSettings() throws {
        var s = settings()
        s.quietHours = .suggested
        s.setEnabled(false, for: .calmedDown)
        s.setEnabled(true, for: .notVisible, camera: hall)
        let reloaded = settings(s.requestPrefs())
        XCTAssertEqual(reloaded.requestPrefs(), s.requestPrefs())
        XCTAssertEqual(reloaded.quietHours, QuietHours.suggested)
        XCTAssertFalse(reloaded.isEnabled(.calmedDown))
        XCTAssertTrue(reloaded.isEnabled(.notVisible, camera: hall))
    }

    // MARK: - API

    func testGetAndPutNotificationPrefs() async throws {
        let json = """
        {"types":[{"eventType":"prolongedBarking","enabledByDefault":true,"bypassesQuietHours":true}],
         "prefs":[{"cameraId":null,"eventType":"prolongedBarking","enabled":false,"quietStart":null,"quietEnd":null},
                  {"cameraId":"\(Fixtures.deviceID)","eventType":"atDoor","enabled":true,"quietStart":"22:00","quietEnd":"07:00"}]}
        """
        let stub = StubTransport(json: json)
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .user(token: "t"), transport: stub)

        let loaded = try await api.notificationPrefs()
        XCTAssertEqual(loaded.types.first?.bypassesQuietHours, true)
        XCTAssertNil(loaded.prefs[0].cameraId)
        XCTAssertEqual(loaded.prefs[1].cameraId, UUID(uuidString: Fixtures.deviceID))
        XCTAssertEqual(loaded.prefs[1].quietStart, "22:00")
        XCTAssertEqual(stub.requests[0].httpMethod, "GET")
        XCTAssertEqual(stub.requests[0].url?.path, "/v1/notification-prefs")

        _ = try await api.replaceNotificationPrefs([
            NotificationPrefDTO(cameraId: nil, eventType: .whining, enabled: false),
            NotificationPrefDTO(cameraId: kitchen, eventType: .atDoor, enabled: true, quietStart: "22:00", quietEnd: "07:00"),
        ])
        let put = stub.requests[1]
        XCTAssertEqual(put.httpMethod, "PUT")
        let rows = try XCTUnwrap(Fixtures.bodyJSON(put)["prefs"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0]["cameraId"] is NSNull, "the backend requires cameraId, so nil is sent as null")
        XCTAssertNil(rows[0]["quietStart"])
        XCTAssertEqual(rows[1]["cameraId"] as? String, kitchen.uuidString.lowercased())
        XCTAssertEqual(rows[1]["quietEnd"] as? String, "07:00")
    }
}
