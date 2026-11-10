import DogMonitorCore
import UIKit
import XCTest
@testable import DogMonitor

/// Replies in order and records what was sent.
private final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Int, Data)]
    private var sent: [URLRequest] = []

    init(_ replies: [(Int, String)]) {
        self.replies = replies.map { ($0.0, Data($0.1.utf8)) }
    }

    var requests: [URLRequest] { lock.withLock { sent } }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock {
            sent.append(request)
            let (status, body) = replies.isEmpty ? (500, Data("{}".utf8)) : replies.removeFirst()
            return HTTPResponse(statusCode: status, body: body)
        }
    }
}

@MainActor
final class DogOnboardingModelTests: XCTestCase {
    private static let dogId = "44444444-4444-4444-8444-444444444444"

    private static func dog(photo: Bool = false) -> String {
        """
        {"id":"\(dogId)","householdId":"33333333-3333-4333-8333-333333333333","name":"Rex","photoKey":null,
         "lifeStage":"adult","traits":["waitsAtDoor"],"alertStyle":"balanced",
         "photoUpdatedAt":\(photo ? "\"2026-11-10T09:00:00.000Z\"" : "null"),"createdAt":"2026-11-10T09:00:00.000Z"}
        """
    }

    private static var prefs: String {
        let types = EventType.allCases.map {
            #"{"eventType":"\#($0.rawValue)","enabledByDefault":\#($0.isEnabledByDefault),"bypassesQuietHours":false}"#
        }
        return #"{"types":[\#(types.joined(separator: ","))],"prefs":[]}"#
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testSaveCreatesTheDogUploadsThePhotoAndAppliesAlerts() async throws {
        let transport = ScriptedTransport([(201, Self.dog()), (200, Self.dog(photo: true)), (200, Self.prefs), (200, Self.prefs)])
        let model = DogOnboardingModel(api: DogMonitorAPI(baseURL: URL(string: "https://api.example.com")!, transport: transport))
        model.name = "  Rex "
        model.lifeStage = .adult
        model.toggle(.waitsAtDoor)
        model.alertStyle = .balanced
        model.photo = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }

        let saved = await model.save()

        XCTAssertTrue(saved)
        XCTAssertFalse(model.saveFailed)
        let requests = transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "PUT", "GET", "PUT"])
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/dogs", "/dogs/\(Self.dogId)/photo", "/notification-prefs", "/notification-prefs",
        ])

        let dog = try body(requests[0])
        XCTAssertEqual(dog["name"] as? String, "Rex")
        XCTAssertEqual(dog["traits"] as? [String], ["waitsAtDoor"])
        XCTAssertEqual(dog["alertStyle"] as? String, "balanced")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertEqual(requests[1].httpBody?.prefix(2), Data([0xFF, 0xD8]))

        let prefs = try XCTUnwrap(try body(requests[3])["prefs"] as? [[String: Any]])
        let atDoor = prefs.first { $0["eventType"] as? String == "atDoor" && ($0["cameraId"] == nil || $0["cameraId"] is NSNull) }
        XCTAssertEqual(atDoor?["enabled"] as? Bool, true, "a dog that waits by the door gets door alerts")
    }

    func testRetryAfterAFailureUpdatesTheSameDog() async throws {
        let transport = ScriptedTransport([(201, Self.dog()), (500, "{}"), (200, Self.dog()), (200, Self.prefs), (200, Self.prefs)])
        let model = DogOnboardingModel(api: DogMonitorAPI(baseURL: URL(string: "https://api.example.com")!, transport: transport))
        model.name = "Rex"

        let first = await model.save()
        XCTAssertFalse(first)
        XCTAssertTrue(model.saveFailed)

        let second = await model.save()
        XCTAssertTrue(second)
        XCTAssertEqual(transport.requests[2].httpMethod, "PATCH", "no second dog on retry")
        XCTAssertEqual(transport.requests[2].url?.path, "/dogs/\(Self.dogId)")
    }

    func testStartsFromAnExistingDog() {
        let dog = DogDTO(id: UUID(), householdId: UUID(), name: "Bella", traits: [.whines], alertStyle: .important, createdAt: .now)
        let model = DogOnboardingModel(api: DogMonitorAPI(baseURL: URL(string: "https://api.example.com")!), dog: dog)
        XCTAssertEqual(model.name, "Bella")
        XCTAssertEqual(model.traits, [.whines])
        XCTAssertEqual(model.alertStyle, .important)
        XCTAssertEqual(model.promises.first, .barking)
    }

    // MARK: Profile editor

    /// The same dog as `dog(photo:)`, already decoded.
    private static func profiledDog(photo: Bool = false) throws -> DogDTO {
        DogDTO(
            id: try XCTUnwrap(UUID(uuidString: dogId)), householdId: UUID(), name: "Rex",
            lifeStage: .adult, traits: [.waitsAtDoor], alertStyle: .balanced,
            photoUpdatedAt: photo ? .now : nil, createdAt: .now
        )
    }

    func testNameAndPhotoAloneDoNotChangeAlerts() throws {
        let model = DogOnboardingModel(api: DogMonitorAPI(baseURL: URL(string: "https://api.example.com")!), dog: try Self.profiledDog())
        model.name = "Rexy"
        model.removePhoto()
        XCTAssertFalse(model.changesAlerts)
        model.toggle(.whines)
        XCTAssertTrue(model.changesAlerts)
        model.toggle(.whines)
        model.alertStyle = .everything
        XCTAssertTrue(model.changesAlerts)
    }

    func testADogWithoutAProfileAlwaysChangesAlerts() {
        let dog = DogDTO(id: UUID(), householdId: UUID(), name: "Bella", createdAt: .now)
        let model = DogOnboardingModel(api: DogMonitorAPI(baseURL: URL(string: "https://api.example.com")!), dog: dog)
        XCTAssertTrue(model.changesAlerts)
    }

    func testSavingWithoutAlertsRemovesThePhotoAndLeavesPrefsAlone() async throws {
        let transport = ScriptedTransport([(200, Self.dog(photo: true)), (200, Self.dog())])
        let api = DogMonitorAPI(baseURL: URL(string: "https://api.example.com")!, transport: transport)
        let model = DogOnboardingModel(api: api, dog: try Self.profiledDog(photo: true))
        model.name = "Rexy"
        model.removePhoto()

        let saved = await model.save(appliesAlerts: false)

        XCTAssertTrue(saved)
        XCTAssertEqual(transport.requests.map(\.httpMethod), ["PATCH", "DELETE"])
        XCTAssertEqual(transport.requests.last?.url?.path, "/dogs/\(Self.dogId)/photo")
        XCTAssertEqual(model.savedDog?.hasPhoto, false)
        XCTAssertFalse(model.photoUploaded)
    }

    func testNameIsRequired() async {
        let model = DogOnboardingModel(api: DogMonitorAPI(baseURL: URL(string: "https://api.example.com")!))
        model.name = "   "
        XCTAssertNil(model.validName)
        let saved = await model.save()
        XCTAssertFalse(saved)
    }

    func testPhotoIsASmallSquare() {
        let wide = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800)).image { _ in }
        let square = DogPhoto.square(wide, side: DogPhoto.uploadSide)
        XCTAssertEqual(square.size.width, DogPhoto.uploadSide)
        XCTAssertEqual(square.size.height, DogPhoto.uploadSide)
        XCTAssertEqual(square.scale, 1)
    }
}
