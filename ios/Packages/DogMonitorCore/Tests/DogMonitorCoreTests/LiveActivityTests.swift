import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import DogMonitorCore

final class LiveActivityTests: XCTestCase {
    private static let cameraID = UUID(uuidString: Fixtures.deviceID)!
    private static let activityID = "7c9e6679-7425-40de-944b-e07fc1f90ae7"

    // MARK: Content state

    func testContentDecodesTheBackendPushPayload() throws {
        let json = #"{"state":"barking","online":true}"#
        let content = try JSONDecoder().decode(CameraLiveActivityContent.self, from: Data(json.utf8))
        XCTAssertEqual(content, CameraLiveActivityContent(state: .barking, online: true))
        XCTAssertEqual(content.displayState, .barking)
        XCTAssertTrue(content.needsAttention)
    }

    func testNullStateDecodesAsNil() throws {
        let json = #"{"state":null,"online":true}"#
        let content = try JSONDecoder().decode(CameraLiveActivityContent.self, from: Data(json.utf8))
        XCTAssertNil(content.state)
        XCTAssertEqual(content.displayState, .unknown)
        XCTAssertFalse(content.needsAttention)
    }

    func testUnknownStateFromANewerServerReadsAsUnknown() throws {
        let json = #"{"state":"zoomies","online":true}"#
        let content = try JSONDecoder().decode(CameraLiveActivityContent.self, from: Data(json.utf8))
        XCTAssertEqual(content.state, .unknown)
    }

    func testOfflineCameraShowsUnknownAndNeedsAttention() {
        let content = CameraLiveActivityContent(state: .resting, online: false)
        XCTAssertEqual(content.displayState, .unknown)
        XCTAssertTrue(content.needsAttention)
    }

    func testCalmStatesDoNotNeedAttention() {
        for state in [DogState.resting, .restless, .notVisible, .unknown] {
            XCTAssertFalse(CameraLiveActivityContent(state: state, online: true).needsAttention, "\(state)")
        }
    }

    func testContentRoundTrips() throws {
        for content in [
            CameraLiveActivityContent(state: .atDoor, online: true),
            CameraLiveActivityContent(state: nil, online: false),
        ] {
            let data = try JSONEncoder().encode(content)
            XCTAssertEqual(try JSONDecoder().decode(CameraLiveActivityContent.self, from: data), content)
        }
    }

    // MARK: API

    func testRegisterSendsCameraAndHexTokenAndDecodesTheRecord() async throws {
        let json = """
        {"id":"\(Self.activityID)","cameraId":"\(Fixtures.deviceID)","createdAt":"2026-11-10T14:00:00.123Z"}
        """
        let stub = StubTransport(json: json)
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .user(token: "jwt"), transport: stub)

        let registration = try await api.registerLiveActivity(
            cameraId: Self.cameraID,
            pushToken: Data([0x0a, 0xbc, 0xde, 0xf0, 0x01, 0x02, 0x03, 0x04])
        )

        XCTAssertEqual(registration.id, UUID(uuidString: Self.activityID))
        XCTAssertEqual(registration.cameraId, Self.cameraID)
        XCTAssertEqual(registration.createdAt, JSONCoding.parseISO8601("2026-11-10T14:00:00.123Z"))

        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/v1/live-activities")
        let body = try Fixtures.bodyJSON(request)
        XCTAssertEqual(body["cameraId"] as? String, Fixtures.deviceID)
        XCTAssertEqual(body["pushToken"] as? String, "0abcdef001020304")
        XCTAssertEqual(body.count, 2)
    }

    func testRegisterSurfacesCameraNotFound() async throws {
        let stub = StubTransport(status: 404, json: #"{"error":"camera_not_found"}"#)
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .user(token: "jwt"), transport: stub)

        do {
            _ = try await api.registerLiveActivity(cameraId: Self.cameraID, pushToken: Data([1, 2, 3, 4, 5, 6, 7, 8]))
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error, .http(status: 404, code: "camera_not_found"))
        }
    }

    func testEndDeletesTheActivityAndAcceptsAnEmptyBody() async throws {
        let stub = StubTransport { _ in HTTPResponse(statusCode: 204, body: Data()) }
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .user(token: "jwt"), transport: stub)

        try await api.endLiveActivity(id: UUID(uuidString: Self.activityID)!)

        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/v1/live-activities/\(Self.activityID)")
        XCTAssertNil(request.httpBody)
    }
}
