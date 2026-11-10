import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import DogMonitorCore

final class DogPersonalizationTests: XCTestCase {
    private static let types: [NotificationTypeInfoDTO] = EventType.allCases.map { type in
        NotificationTypeInfoDTO(
            eventType: type,
            enabledByDefault: type.isEnabledByDefault,
            bypassesQuietHours: type.interruptionLevel == .timeSensitive
        )
    }

    func testBarkingAndWhiningAreAlwaysOn() {
        for style in DogAlertStyle.allCases {
            let plan = DogPersonalization(alertStyle: style)
            XCTAssertEqual(plan.alerts[.prolongedBarking], true, "\(style)")
            XCTAssertEqual(plan.alerts[.whining], true, "\(style)")
        }
    }

    func testImportantOnlyKeepsDistress() {
        let plan = DogPersonalization(traits: [.waitsAtDoor, .getsOnFurniture], alertStyle: .important)
        XCTAssertEqual(plan.alerts, [
            .prolongedBarking: true, .whining: true, .atDoor: false,
            .forbiddenZone: false, .notVisible: false, .calmedDown: false,
        ])
    }

    func testBalancedFollowsTheDogsHabits() {
        let doorDog = DogPersonalization(traits: [.waitsAtDoor], alertStyle: .balanced)
        XCTAssertEqual(doorDog.alerts[.atDoor], true)
        XCTAssertEqual(doorDog.alerts[.forbiddenZone], false)
        XCTAssertEqual(doorDog.alerts[.calmedDown], true)
        XCTAssertEqual(doorDog.alerts[.notVisible], false)

        let sofaDog = DogPersonalization(traits: [.getsOnFurniture], alertStyle: .balanced)
        XCTAssertEqual(sofaDog.alerts[.atDoor], false)
        XCTAssertEqual(sofaDog.alerts[.forbiddenZone], true)
    }

    func testEverythingTurnsOnEveryDogAlert() {
        let plan = DogPersonalization(alertStyle: .everything)
        XCTAssertTrue(plan.alerts.values.allSatisfy { $0 })
        XCTAssertEqual(Set(plan.alerts.keys), Set(DogPersonalization.dogEventTypes))
    }

    func testApplyChangesOnlyDogAlertsAtHouseholdLevel() {
        let camera = UUID()
        var settings = NotificationSettings(NotificationPrefsDTO(types: Self.types, prefs: [
            NotificationPrefDTO(cameraId: nil, eventType: .cameraOffline, enabled: false, quietStart: "22:00", quietEnd: "07:00"),
            NotificationPrefDTO(cameraId: camera, eventType: .atDoor, enabled: false, quietStart: nil, quietEnd: nil),
        ]))
        DogPersonalization(traits: [.waitsAtDoor], alertStyle: .balanced).apply(to: &settings)

        XCTAssertTrue(settings.isEnabled(.atDoor))
        XCTAssertTrue(settings.isEnabled(.calmedDown))
        XCTAssertFalse(settings.isEnabled(.forbiddenZone))
        XCTAssertFalse(settings.isEnabled(.cameraOffline), "camera alerts keep the owner's choice")
        XCTAssertFalse(settings.isEnabled(.atDoor, camera: camera), "camera overrides stay")
        XCTAssertNotNil(settings.quietHours, "quiet hours stay")
    }

    func testPromisesMatchTheAnswers() {
        let plan = DogPersonalization(
            lifeStage: .puppy,
            traits: [.whines, .waitsAtDoor, .getsOnFurniture, .mostlySleeps],
            alertStyle: .balanced
        )
        XCTAssertEqual(plan.promises(hasZones: false), [
            .barking, .whining, .atDoor, .furniture(needsZone: true), .calmedDown,
            .quietWhenSleeping, .puppyProgress, .dailySummary,
        ])
        XCTAssertTrue(plan.promises(hasZones: true).contains(.furniture(needsZone: false)))

        let quiet = DogPersonalization(traits: [.waitsAtDoor], alertStyle: .important)
        XCTAssertEqual(quiet.promises(), [.barking, .dailySummary])

        let everything = DogPersonalization(traits: [.mostlySleeps], alertStyle: .everything)
        XCTAssertFalse(everything.promises().contains(.quietWhenSleeping))
    }

    func testDogInputKeepsTraitOrderStable() {
        let input = DogPersonalization(lifeStage: .senior, traits: [.mostlySleeps, .barksAtNoises], alertStyle: .important)
            .dogInput(name: "Rex")
        XCTAssertEqual(input.name, "Rex")
        XCTAssertEqual(input.traits, [.barksAtNoises, .mostlySleeps])
        XCTAssertEqual(input.lifeStage, .senior)
        XCTAssertEqual(input.alertStyle, .important)
    }

    func testInitFromDogDefaultsToBalanced() {
        let dog = DogDTO(id: UUID(), householdId: UUID(), name: "Rex", traits: [.whines], createdAt: .now)
        let plan = DogPersonalization(dog)
        XCTAssertEqual(plan.alertStyle, .balanced)
        XCTAssertEqual(plan.traits, [.whines])
    }
}

final class DogProfileAPITests: XCTestCase {
    private static let dogJSON = """
    {"id":"\(Fixtures.userID)","householdId":"\(Fixtures.householdID)","name":"Rex","photoKey":null,
     "lifeStage":"adult","traits":["waitsAtDoor","chasesSquirrels","whines"],"alertStyle":"balanced",
     "photoUpdatedAt":"2026-11-10T07:00:00.000Z","createdAt":"2026-11-10T07:00:00.000Z"}
    """

    func testDecodesProfileAndDropsUnknownValues() async throws {
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, transport: StubTransport(json: "[\(Self.dogJSON)]"))
        let dog = try XCTUnwrap(try await api.dogs().first)
        XCTAssertEqual(dog.lifeStage, .adult)
        XCTAssertEqual(dog.traits, [.waitsAtDoor, .whines])
        XCTAssertEqual(dog.alertStyle, .balanced)
        XCTAssertTrue(dog.hasPhoto)
    }

    func testDecodesDogsFromOlderServers() async throws {
        let old = #"[{"id":"\#(Fixtures.userID)","householdId":"\#(Fixtures.householdID)","name":"Rex","photoKey":null,"createdAt":"2026-11-10T07:00:00Z"}]"#
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, transport: StubTransport(json: old))
        let dog = try XCTUnwrap(try await api.dogs().first)
        XCTAssertNil(dog.lifeStage)
        XCTAssertEqual(dog.traits, [])
        XCTAssertNil(dog.alertStyle)
        XCTAssertFalse(dog.hasPhoto)
    }

    func testCreateDogSendsProfile() async throws {
        let stub = StubTransport(json: Self.dogJSON)
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, transport: stub)
        _ = try await api.createDog(
            DogPersonalization(lifeStage: .adult, traits: [.whines, .waitsAtDoor], alertStyle: .balanced).dogInput(name: "Rex")
        )
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/dogs")
        let body = try Fixtures.bodyJSON(request)
        XCTAssertEqual(body["name"] as? String, "Rex")
        XCTAssertEqual(body["lifeStage"] as? String, "adult")
        XCTAssertEqual(body["traits"] as? [String], ["whines", "waitsAtDoor"])
        XCTAssertEqual(body["alertStyle"] as? String, "balanced")
        XCTAssertNil(body["photoKey"])
    }

    func testPhotoUploadDownloadAndDelete() async throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        let dogJSON = Self.dogJSON
        let stub = StubTransport { request in
            if request.httpMethod == "GET" {
                return HTTPResponse(statusCode: 200, body: jpeg)
            }
            return HTTPResponse(statusCode: 200, body: Data(dogJSON.utf8))
        }
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .user(token: "jwt"), transport: stub)
        let id = try XCTUnwrap(UUID(uuidString: Fixtures.userID))

        _ = try await api.uploadDogPhoto(id: id, jpeg: jpeg)
        let downloaded = try await api.dogPhoto(id: id)
        _ = try await api.deleteDogPhoto(id: id)

        let put = stub.requests[0]
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertEqual(put.url?.path, "/v1/dogs/\(Fixtures.userID)/photo")
        XCTAssertEqual(put.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertEqual(put.httpBody, jpeg)
        XCTAssertEqual(put.value(forHTTPHeaderField: "Authorization"), "Bearer jwt")
        XCTAssertEqual(downloaded, jpeg)
        XCTAssertEqual(stub.requests[1].value(forHTTPHeaderField: "Accept"), "image/jpeg")
        XCTAssertEqual(stub.requests[2].httpMethod, "DELETE")
    }
}
