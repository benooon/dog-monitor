import DogMonitorCore
import XCTest
@testable import DogMonitor

/// Answers requests from a queue of (status, body) responses, and records the requests.
private final class QueueTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Int, String)]
    private var sent: [URLRequest] = []

    init(_ responses: [(Int, String)]) {
        self.responses = responses
    }

    var requests: [URLRequest] { lock.withLock { sent } }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock {
            sent.append(request)
            let (status, body) = responses.isEmpty ? (500, "{}") : responses.removeFirst()
            return HTTPResponse(statusCode: status, body: Data(body.utf8))
        }
    }
}

@MainActor
final class TimelineModelTests: XCTestCase {
    private static let first = "11111111-1111-4111-8111-111111111111"
    private static let second = "22222222-2222-4222-8222-222222222222"

    private static func event(_ id: String, feedback: String = "null") -> String {
        """
        {"id":"\(id)","householdId":"33333333-3333-4333-8333-333333333333","cameraId":null,
         "type":"prolongedBarking","state":"barking","startedAt":"2026-11-10T09:00:00.000Z",
         "endedAt":null,"confidence":0.9,"clipKey":null,"snapshotKey":null,"feedback":\(feedback)}
        """
    }

    private static func page(_ events: [String], cursor: String? = nil) -> String {
        let next = cursor.map { "\"\($0)\"" } ?? "null"
        return #"{"events":[\#(events.joined(separator: ","))],"nextCursor":\#(next)}"#
    }

    private func makeModel(_ transport: QueueTransport) -> TimelineModel {
        let api = DogMonitorAPI(baseURL: URL(string: "https://api.example.com")!, credential: .user(token: "t"), transport: transport)
        return TimelineModel(api: api, cameras: [])
    }

    func testRefreshThenLoadMoreAppendsTheNextPage() async throws {
        let transport = QueueTransport([
            (200, Self.page([Self.event(Self.first)], cursor: "c1")),
            (200, Self.page([Self.event(Self.second)])),
        ])
        let model = makeModel(transport)

        await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.feed.hasMore)

        await model.loadMore()
        XCTAssertEqual(model.feed.events.count, 2)
        XCTAssertFalse(model.feed.hasMore)
        let query = try XCTUnwrap(transport.requests.last?.url?.query)
        XCTAssertTrue(query.contains("cursor=c1"), query)
    }

    func testFailedFirstLoadShowsTheError() async {
        let model = makeModel(QueueTransport([(500, #"{"error":"internal"}"#)]))

        await model.refresh()

        XCTAssertEqual(model.phase, .failed)
    }

    func testStaleCursorStartsOver() async {
        let transport = QueueTransport([
            (200, Self.page([Self.event(Self.first)], cursor: "old")),
            (400, #"{"error":"invalid_cursor"}"#),
            (200, Self.page([Self.event(Self.second)])),
        ])
        let model = makeModel(transport)

        await model.refresh()
        await model.loadMore()

        XCTAssertEqual(model.feed.events.map(\.id.uuidString), [Self.second.uppercased()])
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testFeedbackTogglesAndTappingAgainClears() async throws {
        let transport = QueueTransport([
            (200, Self.page([Self.event(Self.first)])),
            (200, Self.event(Self.first, feedback: #""wrong""#)),
            (200, Self.event(Self.first)),
        ])
        let model = makeModel(transport)
        await model.refresh()
        let event = try XCTUnwrap(model.feed.events.first)

        await model.toggleFeedback(.wrong, for: event)
        XCTAssertEqual(model.feed.events.first?.feedback, .wrong)
        XCTAssertEqual(transport.requests.last?.httpMethod, "PUT")

        await model.toggleFeedback(.wrong, for: event)
        XCTAssertNil(model.feed.events.first?.feedback)
        let body = try XCTUnwrap(transport.requests.last?.httpBody)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"feedback":null}"#)
    }

    func testFailedFeedbackRollsBack() async throws {
        let transport = QueueTransport([
            (200, Self.page([Self.event(Self.first)])),
            (500, #"{"error":"internal"}"#),
        ])
        let model = makeModel(transport)
        await model.refresh()
        let event = try XCTUnwrap(model.feed.events.first)

        await model.toggleFeedback(.correct, for: event)

        XCTAssertNil(model.feed.events.first?.feedback)
        XCTAssertTrue(model.feedbackFailed)
    }
}
