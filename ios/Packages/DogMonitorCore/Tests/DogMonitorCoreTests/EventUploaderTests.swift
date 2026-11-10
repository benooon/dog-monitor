import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import DogMonitorCore

final class EventUploaderTests: XCTestCase {
    private let cameraID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ id: String, endedAt: Date? = nil) -> DogEvent {
        DogEvent(id: UUID(uuidString: id)!, cameraID: cameraID, type: .prolongedBarking, startedAt: t0, endedAt: endedAt, confidence: 0.9)
    }

    private let eventJSON = #"{"id":"22222222-2222-4222-8222-222222222222","householdId":"33333333-3333-4333-8333-333333333333","cameraId":null,"type":"prolongedBarking","state":"barking","startedAt":"2027-01-15T08:00:00.000Z","endedAt":null,"confidence":0.9,"clipKey":null,"snapshotKey":null}"#

    private func api(_ transport: StubTransport) -> DogMonitorAPI {
        DogMonitorAPI(baseURL: URL(string: "https://api.example.com")!, credential: .device(id: cameraID, secret: "s"), transport: transport)
    }

    func testMapsEngineOutputsToUploads() {
        let e = event("22222222-2222-4222-8222-222222222222")
        XCTAssertEqual(EventUpload.uploads(for: .started(e)), [.create(CreateEventRequest(e))])
        XCTAssertEqual(EventUpload.uploads(for: .resumed(e)), [])
        XCTAssertEqual(EventUpload.uploads(for: .escalated(e, duration: 300)), [.update(id: e.id, UpdateEventRequest(escalationSeconds: 300))])
        let ended = event("22222222-2222-4222-8222-222222222222", endedAt: t0 + 120)
        XCTAssertEqual(EventUpload.uploads(for: .ended(ended)), [.update(id: e.id, UpdateEventRequest(endedAt: t0 + 120))])
    }

    func testSendsInOrderAndEmptiesTheQueue() async throws {
        let transport = StubTransport(json: eventJSON)
        let uploader = EventUploader(store: InMemoryEventQueueStore())
        let e = event("22222222-2222-4222-8222-222222222222")
        await uploader.enqueue([.started(e), .escalated(e, duration: 300)])

        let sent = await uploader.flush(using: api(transport))
        XCTAssertEqual(sent, 2)
        let pending = await uploader.pending
        XCTAssertTrue(pending.isEmpty)

        let requests = transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "PATCH"])
        XCTAssertEqual(requests.map { $0.url?.path }, ["/events", "/events/22222222-2222-4222-8222-222222222222"])
        let body = try XCTUnwrap(requests[1].httpBody)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"escalationSeconds":300}"#)
    }

    func testKeepsItemsWhenOfflineAndPersistsThem() async {
        let store = InMemoryEventQueueStore()
        let offline = StubTransport { _ in throw URLError(.notConnectedToInternet) }
        let uploader = EventUploader(store: store)
        await uploader.enqueue([.started(event("22222222-2222-4222-8222-222222222222"))])

        let sent = await uploader.flush(using: api(offline))
        XCTAssertEqual(sent, 0)
        let pending = await uploader.pending
        XCTAssertEqual(pending.count, 1)

        // A new launch reads the same queue back.
        let restored = EventUploader(store: store)
        let restoredPending = await restored.pending
        XCTAssertEqual(restoredPending, pending)

        let online = StubTransport(json: eventJSON)
        let resent = await restored.flush(using: api(online))
        XCTAssertEqual(resent, 1)
        XCTAssertNil(store.load(), "empty queue removes the file")
    }

    func testDropsRejectedItemsButStopsOnServerErrors() async {
        let uploader = EventUploader(store: InMemoryEventQueueStore())
        await uploader.enqueue([
            .started(event("22222222-2222-4222-8222-222222222222")),
            .started(event("44444444-4444-4444-8444-444444444444")),
        ])
        let rejected = StubTransport(status: 400, json: #"{"error":"bad_request"}"#)
        _ = await uploader.flush(using: api(rejected))
        let afterRejection = await uploader.pending
        XCTAssertTrue(afterRejection.isEmpty)

        await uploader.enqueue([.started(event("55555555-5555-4555-8555-555555555555"))])
        let down = StubTransport(status: 503, json: #"{"error":"unavailable"}"#)
        _ = await uploader.flush(using: api(down))
        let afterOutage = await uploader.pending
        XCTAssertEqual(afterOutage.count, 1)
    }

    func testFileStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("queue.json")
        let store = FileEventQueueStore(url: url)
        XCTAssertNil(store.load())
        try store.save(Data("[]".utf8))
        XCTAssertEqual(store.load(), Data("[]".utf8))
        try store.save(nil)
        XCTAssertNil(store.load())
    }
}
