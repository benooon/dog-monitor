import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import DogMonitorCore

final class MediaUploaderTests: XCTestCase {
    private let cameraID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let eventID = UUID(uuidString: "2222AAAA-2222-4222-8222-222222222222")!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private static let eventJSON = #"{"id":"2222aaaa-2222-4222-8222-222222222222","householdId":"33333333-3333-4333-8333-333333333333","cameraId":null,"type":"prolongedBarking","state":"barking","startedAt":"2027-01-15T08:00:00.000Z","endedAt":null,"confidence":0.9,"clipKey":null,"snapshotKey":null}"#

    private static func uploadsJSON(_ kind: String, contentType: String) -> String {
        #"{"uploads":{"\#(kind)":{"key":"households/h/cameras/c/events/e/\#(kind)","url":"https://bucket.example.com/\#(kind)?X-Amz-Signature=abc","headers":{"Content-Type":"\#(contentType)"},"expiresAt":"2027-01-15T08:15:00.000Z"}}}"#
    }

    /// Answers like the backend + bucket; `patchStatus` lets tests fail the attach step.
    private func backend(patchStatus: Int = 200) -> StubTransport {
        StubTransport { request in
            let path = request.url?.path ?? ""
            switch (request.httpMethod, request.url?.host) {
            case ("PUT", "bucket.example.com"):
                return HTTPResponse(statusCode: 200, body: Data())
            case ("POST", _) where path == "/device/uploads":
                let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                let kind = (body?["kinds"] as? [String])?.first ?? "clip"
                let json = Self.uploadsJSON(kind, contentType: kind == "clip" ? "video/mp4" : "image/jpeg")
                return HTTPResponse(statusCode: 200, body: Data(json.utf8))
            case ("PATCH", _):
                let body = patchStatus == 200 ? Self.eventJSON : #"{"error":"not_found"}"#
                return HTTPResponse(statusCode: patchStatus, body: Data(body.utf8))
            default:
                return HTTPResponse(statusCode: 500, body: Data())
            }
        }
    }

    private func api(_ transport: StubTransport) -> DogMonitorAPI {
        DogMonitorAPI(baseURL: URL(string: "https://api.example.com")!, credential: .device(id: cameraID, secret: "s"), transport: transport)
    }

    private func writeFile(_ kind: MediaKind, for uploader: MediaUploader) throws -> URL {
        let url = uploader.fileURL(eventID: eventID, kind: kind)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("media".utf8).write(to: url)
        return url
    }

    func testFileLayoutMatchesRecorder() {
        let uploader = MediaUploader(directory: directory, store: InMemoryEventQueueStore())
        XCTAssertEqual(
            uploader.fileURL(eventID: eventID, kind: .clip).path,
            directory.appendingPathComponent("2222AAAA-2222-4222-8222-222222222222/clip.mp4").path
        )
    }

    func testUploadsClipAndAttachesItToTheEvent() async throws {
        let transport = backend()
        let uploader = MediaUploader(directory: directory, store: InMemoryEventQueueStore())
        let file = try writeFile(.clip, for: uploader)
        await uploader.enqueue(eventID: eventID, kind: .clip)

        let attached = await uploader.flush(using: api(transport))
        XCTAssertEqual(attached, 1)
        let pending = await uploader.pending
        XCTAssertTrue(pending.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))

        let requests = transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "PUT", "PATCH"])

        let ask = try Fixtures.bodyJSON(requests[0])
        XCTAssertEqual(ask["eventId"] as? String, "2222aaaa-2222-4222-8222-222222222222")
        XCTAssertEqual(ask["kinds"] as? [String], ["clip"])

        let put = requests[1]
        XCTAssertEqual(put.url?.absoluteString, "https://bucket.example.com/clip?X-Amz-Signature=abc")
        XCTAssertEqual(put.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertNil(put.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(put.httpBody, Data("media".utf8))

        XCTAssertEqual(requests[2].url?.path, "/events/2222aaaa-2222-4222-8222-222222222222")
        let patch = try Fixtures.bodyJSON(requests[2])
        XCTAssertEqual(patch["clipKey"] as? String, "households/h/cameras/c/events/e/clip")
    }

    func testOfflineKeepsTheQueueAcrossLaunches() async throws {
        let store = InMemoryEventQueueStore()
        let uploader = MediaUploader(directory: directory, store: store)
        let file = try writeFile(.snapshot, for: uploader)
        await uploader.enqueue(eventID: eventID, kind: .snapshot)

        let offline = StubTransport { _ in throw URLError(.notConnectedToInternet) }
        let attached = await uploader.flush(using: api(offline))
        XCTAssertEqual(attached, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let relaunched = MediaUploader(directory: directory, store: store)
        let pending = await relaunched.pending
        XCTAssertEqual(pending.map(\.kind), [.snapshot])
        XCTAssertEqual(pending.first?.attempts, 0)
        let sent = await relaunched.flush(using: api(backend()))
        XCTAssertEqual(sent, 1)
    }

    func testEventNotCreatedYetIsRetriedLater() async throws {
        let uploader = MediaUploader(directory: directory, store: InMemoryEventQueueStore())
        let file = try writeFile(.clip, for: uploader)
        await uploader.enqueue(eventID: eventID, kind: .clip)

        let attached = await uploader.flush(using: api(backend(patchStatus: 404)))
        XCTAssertEqual(attached, 0)
        let pending = await uploader.pending
        XCTAssertEqual(pending.first?.attempts, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testRejectedUploadIsDropped() async throws {
        let uploader = MediaUploader(directory: directory, store: InMemoryEventQueueStore())
        let file = try writeFile(.clip, for: uploader)
        await uploader.enqueue(eventID: eventID, kind: .clip)

        _ = await uploader.flush(using: api(backend(patchStatus: 400)))
        let pending = await uploader.pending
        XCTAssertTrue(pending.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testMissingFileIsDropped() async {
        let transport = backend()
        let uploader = MediaUploader(directory: directory, store: InMemoryEventQueueStore())
        await uploader.enqueue(eventID: eventID, kind: .clip)
        let attached = await uploader.flush(using: api(transport))
        XCTAssertEqual(attached, 0)
        let pending = await uploader.pending
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testExpiredItemsAreDropped() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = MediaTestClock(start)
        let transport = backend()
        let uploader = MediaUploader(directory: directory, store: InMemoryEventQueueStore(), now: { clock.now })
        let file = try writeFile(.clip, for: uploader)
        await uploader.enqueue(eventID: eventID, kind: .clip)

        clock.now = start + MediaUploader.maxAge + 1
        let attached = await uploader.flush(using: api(transport))
        XCTAssertEqual(attached, 0)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testDuplicateEnqueueIsIgnored() async {
        let uploader = MediaUploader(directory: directory, store: InMemoryEventQueueStore())
        await uploader.enqueue(eventID: eventID, kind: .clip)
        await uploader.enqueue(eventID: eventID, kind: .clip)
        await uploader.enqueue(eventID: eventID, kind: .snapshot)
        let pending = await uploader.pending
        XCTAssertEqual(pending.map(\.kind), [.clip, .snapshot])
    }

    func testUploadNowReturnsTheKeyWithoutPatching() async throws {
        let transport = backend()
        let uploader = MediaUploader(directory: directory, store: InMemoryEventQueueStore())
        let file = try writeFile(.snapshot, for: uploader)

        let key = try await uploader.uploadNow(eventID: eventID, kind: .snapshot, using: api(transport))
        XCTAssertEqual(key, "households/h/cameras/c/events/e/snapshot")
        XCTAssertEqual(transport.requests.map(\.httpMethod), ["POST", "PUT"])
        XCTAssertEqual(transport.requests[1].value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}

private final class MediaTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date

    init(_ now: Date) {
        _now = now
    }

    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
}
