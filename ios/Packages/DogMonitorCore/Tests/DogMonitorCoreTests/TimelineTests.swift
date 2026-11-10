import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import DogMonitorCore

final class TimelineTests: XCTestCase {
    private static let eventID = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
    private static let otherEventID = "3f2504e0-4f89-41d3-9a0c-0305e82c3302"
    private static let cursor = "2026-11-10T09:00:00.000Z_\(otherEventID)"

    private static func eventJSON(id: String, type: String = "prolongedBarking", feedback: String = "null") -> String {
        """
        {"id":"\(id)","householdId":"\(Fixtures.householdID)","cameraId":"\(Fixtures.deviceID)",
         "type":"\(type)","state":"barking","startedAt":"2026-11-10T09:00:00.000Z",
         "endedAt":"2026-11-10T09:02:30.000Z","confidence":0.92,"clipKey":"clips/a.mp4",
         "snapshotKey":"snapshots/a.jpg","feedback":\(feedback)}
        """
    }

    private func makeAPI(_ stub: StubTransport) -> DogMonitorAPI {
        DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .user(token: "jwt"), transport: stub)
    }

    // MARK: GET /events

    func testTimelineWithoutFilterSendsNoQuery() async throws {
        let stub = StubTransport(json: #"{"events":[],"nextCursor":null}"#)

        let page = try await makeAPI(stub).timeline()

        XCTAssertEqual(page.events, [])
        XCTAssertFalse(page.hasMore)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v1/events")
        XCTAssertNil(request.url?.query)
    }

    func testTimelineSendsFiltersCursorAndLimit() async throws {
        let stub = StubTransport(json: #"{"events":[],"nextCursor":null}"#)
        let filter = TimelineFilter(cameraId: UUID(uuidString: Fixtures.deviceID), types: [.whining, .atDoor])

        _ = try await makeAPI(stub).timeline(filter, cursor: Self.cursor, limit: 20)

        let url = try XCTUnwrap(stub.requests.first?.url)
        XCTAssertEqual(url.path, "/v1/events")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items, [
            URLQueryItem(name: "cameraId", value: Fixtures.deviceID),
            URLQueryItem(name: "types", value: "atDoor,whining"),
            URLQueryItem(name: "cursor", value: Self.cursor),
            URLQueryItem(name: "limit", value: "20"),
        ])
    }

    func testTimelineDecodesEventsFeedbackAndCursor() async throws {
        let json = """
        {"events":[\(Self.eventJSON(id: Self.eventID, feedback: #""wrong""#))],"nextCursor":"\(Self.cursor)"}
        """
        let page = try await makeAPI(StubTransport(json: json)).timeline()

        XCTAssertEqual(page.nextCursor, Self.cursor)
        XCTAssertTrue(page.hasMore)
        let event = try XCTUnwrap(page.events.first)
        XCTAssertEqual(event.id, UUID(uuidString: Self.eventID))
        XCTAssertEqual(event.type, .prolongedBarking)
        XCTAssertEqual(event.state, .barking)
        XCTAssertEqual(event.feedback, .wrong)
        XCTAssertEqual(event.endedAt, JSONCoding.parseISO8601("2026-11-10T09:02:30.000Z"))
    }

    func testTimelineSkipsEventsThisVersionCannotRead() async throws {
        let json = """
        {"events":[\(Self.eventJSON(id: Self.eventID, type: "somethingNew")),\(Self.eventJSON(id: Self.otherEventID))],
         "nextCursor":null}
        """
        let page = try await makeAPI(StubTransport(json: json)).timeline()

        XCTAssertEqual(page.events.map(\.id), [UUID(uuidString: Self.otherEventID)!])
    }

    func testEventWithoutFeedbackFieldStillDecodes() throws {
        // Older servers (and POST /events responses before feedback existed) omit the field.
        let json = """
        {"id":"\(Self.eventID)","householdId":"\(Fixtures.householdID)","cameraId":null,"type":"cameraOffline",
         "state":null,"startedAt":"2026-11-10T09:00:00Z","endedAt":null,"confidence":null,
         "clipKey":null,"snapshotKey":null}
        """
        let event = try JSONCoding.makeDecoder().decode(EventDTO.self, from: Data(json.utf8))
        XCTAssertNil(event.feedback)
        XCTAssertNil(event.cameraId)
    }

    func testStaleCursorSurfacesItsCode() async throws {
        let stub = StubTransport(status: 400, json: #"{"error":"invalid_cursor"}"#)
        do {
            _ = try await makeAPI(stub).timeline(cursor: "nope")
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "invalid_cursor")
        }
    }

    // MARK: PUT /events/:id/feedback

    func testSetFeedbackSendsTheVerdict() async throws {
        let stub = StubTransport(json: Self.eventJSON(id: Self.eventID, feedback: #""correct""#))

        let event = try await makeAPI(stub).setFeedback(eventId: UUID(uuidString: Self.eventID)!, .correct)

        XCTAssertEqual(event.feedback, .correct)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/v1/events/\(Self.eventID)/feedback")
        let body = try Fixtures.bodyJSON(request)
        XCTAssertEqual(body["feedback"] as? String, "correct")
    }

    func testClearingFeedbackSendsNull() async throws {
        let stub = StubTransport(json: Self.eventJSON(id: Self.eventID))

        let event = try await makeAPI(stub).setFeedback(eventId: UUID(uuidString: Self.eventID)!, nil)

        XCTAssertNil(event.feedback)
        let body = try XCTUnwrap(stub.requests.first?.httpBody)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"feedback":null}"#)
    }

    // MARK: GET /events/:id/media

    func testEventMediaDecodesURLsAndExpiry() async throws {
        let json = """
        {"clipUrl":"https://bucket.example.com/clips/a.mp4?sig=1","snapshotUrl":null,
         "expiresAt":"2026-11-10T15:00:00.000Z"}
        """
        let stub = StubTransport(json: json)

        let media = try await makeAPI(stub).eventMedia(eventId: UUID(uuidString: Self.eventID)!)

        XCTAssertEqual(media.clipUrl, URL(string: "https://bucket.example.com/clips/a.mp4?sig=1"))
        XCTAssertNil(media.snapshotUrl)
        let expiry = try XCTUnwrap(JSONCoding.parseISO8601("2026-11-10T15:00:00.000Z"))
        XCTAssertFalse(media.isExpired(at: expiry.addingTimeInterval(-1)))
        XCTAssertTrue(media.isExpired(at: expiry))
        XCTAssertEqual(stub.requests.first?.url?.path, "/v1/events/\(Self.eventID)/media")
    }

    func testEventMediaWithoutStorageSurfacesItsCode() async throws {
        let stub = StubTransport(status: 503, json: #"{"error":"storage_not_configured"}"#)
        do {
            _ = try await makeAPI(stub).eventMedia(eventId: UUID(uuidString: Self.eventID)!)
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error, .http(status: 503, code: "storage_not_configured"))
        }
    }
}
