import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import DogMonitorCore

final class RealtimeMessageTests: XCTestCase {
    private let cameraId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private func decode(_ json: String) throws -> RealtimeServerMessage {
        try RealtimeServerMessage.decode(Data(json.utf8))
    }

    func testDecodesServerMessages() throws {
        XCTAssertEqual(try decode(#"{"type":"viewers","count":2,"change":"joined"}"#), .viewers(count: 2, change: .joined))
        XCTAssertEqual(
            try decode(#"{"type":"cameras","cameras":[{"id":"11111111-1111-4111-8111-111111111111","online":true}]}"#),
            .cameras([.init(id: cameraId, online: true)])
        )
        XCTAssertEqual(
            try decode(#"{"type":"presence","cameraId":"11111111-1111-4111-8111-111111111111","online":false}"#),
            .presence(cameraId: cameraId, online: false)
        )
        XCTAssertEqual(
            try decode(#"{"type":"cameraState","cameraId":"11111111-1111-4111-8111-111111111111","state":"barking"}"#),
            .cameraState(cameraId: cameraId, state: .barking)
        )
        XCTAssertEqual(
            try decode(#"{"type":"cameraState","cameraId":"11111111-1111-4111-8111-111111111111","state":"zooming"}"#),
            .unknown(type: "cameraState")
        )
        let withState = try decode(#"{"type":"cameras","cameras":[{"id":"11111111-1111-4111-8111-111111111111","online":true,"state":"resting"}]}"#)
        guard case .cameras(let cameras) = withState else { return XCTFail("expected cameras") }
        XCTAssertEqual(cameras.first?.dogState, .resting)
        XCTAssertEqual(try decode(#"{"type":"error","error":"not_found"}"#), .error("not_found"))
        XCTAssertEqual(try decode(#"{"type":"future","x":1}"#), .unknown(type: "future"))
    }

    func testRejectsMalformedMessages() {
        XCTAssertThrowsError(try decode(#"{"type":"viewers"}"#))
        XCTAssertThrowsError(try decode(#"{"count":1}"#))
        XCTAssertThrowsError(try decode("nope"))
    }

    func testEncodesClientMessages() throws {
        let health = CameraHealth(batteryLevel: 0.5, isCharging: true, thermalState: .fair, network: .wifi, reportedAt: Date())
        XCTAssertEqual(
            String(decoding: try RealtimeClientMessage.heartbeat(health).encoded(), as: UTF8.self),
            #"{"battery":0.5,"charging":true,"thermal":"fair","type":"heartbeat"}"#
        )
        XCTAssertEqual(
            String(decoding: try RealtimeClientMessage.heartbeat(health, dogState: .barking).encoded(), as: UTF8.self),
            #"{"battery":0.5,"charging":true,"state":"barking","thermal":"fair","type":"heartbeat"}"#
        )
        XCTAssertEqual(
            String(decoding: try RealtimeClientMessage.heartbeat(health, liveKeyMissing: true).encoded(), as: UTF8.self),
            #"{"battery":0.5,"charging":true,"liveKeyMissing":true,"thermal":"fair","type":"heartbeat"}"#
        )
        let unknownBattery = CameraHealth(batteryLevel: nil, isCharging: false, thermalState: .nominal, network: .wifi, reportedAt: Date())
        XCTAssertEqual(
            String(decoding: try RealtimeClientMessage.heartbeat(unknownBattery).encoded(), as: UTF8.self),
            #"{"charging":false,"thermal":"nominal","type":"heartbeat"}"#
        )
        XCTAssertEqual(
            String(decoding: try RealtimeClientMessage.watch(cameraId: cameraId).encoded(), as: UTF8.self),
            #"{"cameraId":"11111111-1111-4111-8111-111111111111","type":"watch"}"#
        )
        XCTAssertEqual(
            String(decoding: try RealtimeClientMessage.unwatch(cameraId: cameraId).encoded(), as: UTF8.self),
            #"{"cameraId":"11111111-1111-4111-8111-111111111111","type":"unwatch"}"#
        )
    }
}

final class PublishPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 10_000)

    func testIdleUntilAViewerJoins() {
        var policy = PublishPolicy()
        XCTAssertFalse(policy.shouldPublish(at: t0))
        policy.viewersChanged(to: 1, at: t0)
        XCTAssertTrue(policy.shouldPublish(at: t0))
        XCTAssertNil(policy.stopDeadline(after: t0))
    }

    func testKeepsPublishingForTheLingerAfterTheLastViewerLeaves() {
        var policy = PublishPolicy(linger: 30)
        policy.viewersChanged(to: 2, at: t0)
        policy.viewersChanged(to: 1, at: t0 + 5)
        XCTAssertNil(policy.lastViewerLeftAt)
        policy.viewersChanged(to: 0, at: t0 + 10)
        XCTAssertTrue(policy.shouldPublish(at: t0 + 39))
        XCTAssertEqual(policy.stopDeadline(after: t0 + 20), t0 + 40)
        XCTAssertFalse(policy.shouldPublish(at: t0 + 40))
        XCTAssertNil(policy.stopDeadline(after: t0 + 40))
    }

    func testRejoinWithinLingerCancelsTheStop() {
        var policy = PublishPolicy(linger: 30)
        policy.viewersChanged(to: 1, at: t0)
        policy.viewersChanged(to: 0, at: t0 + 10)
        policy.viewersChanged(to: 1, at: t0 + 20)
        XCTAssertTrue(policy.shouldPublish(at: t0 + 100))
        XCTAssertNil(policy.stopDeadline(after: t0 + 20))
    }

    func testRepeatedZeroDoesNotExtendTheLinger() {
        var policy = PublishPolicy(linger: 30)
        policy.viewersChanged(to: 1, at: t0)
        policy.viewersChanged(to: 0, at: t0 + 10)
        policy.viewersChanged(to: 0, at: t0 + 25)
        XCTAssertFalse(policy.shouldPublish(at: t0 + 40))
    }

    func testConnectionLostWindsDown() {
        var policy = PublishPolicy(linger: 30)
        policy.viewersChanged(to: 3, at: t0)
        policy.connectionLost(at: t0 + 1)
        XCTAssertTrue(policy.shouldPublish(at: t0 + 2))
        XCTAssertFalse(policy.shouldPublish(at: t0 + 31))
    }
}

final class ReconnectBackoffTests: XCTestCase {
    func testDoublesUpToTheCapAndResets() {
        var backoff = ReconnectBackoff(initial: 1, maximum: 8, jitter: 0)
        let delays = (0..<6).map { _ in backoff.nextDelay(random: 0) }
        XCTAssertEqual(delays, [1, 2, 4, 8, 8, 8])
        backoff.reset()
        XCTAssertEqual(backoff.nextDelay(random: 0), 1)
    }

    func testJitterOnlyShortens() {
        var backoff = ReconnectBackoff(initial: 10, maximum: 10, jitter: 0.5)
        XCTAssertEqual(backoff.nextDelay(random: 1), 5)
        XCTAssertEqual(backoff.nextDelay(random: 0), 10)
    }
}

final class LiveAPITests: XCTestCase {
    func testLiveTokenRequests() async throws {
        let transport = StubTransport(json: #"{"url":"wss://x.livekit.cloud","token":"t","room":"camera-1","identity":"viewer:u:1","expiresAt":"2026-01-01T00:10:00.000Z"}"#)
        let cameraId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let api = DogMonitorAPI(baseURL: URL(string: "https://api.example.com")!, credential: .user(token: "jwt"), transport: transport)

        let token = try await api.liveToken(cameraId: cameraId)
        XCTAssertEqual(token.room, "camera-1")
        XCTAssertEqual(token.expiresAt, Date(timeIntervalSince1970: 1_767_226_200))
        _ = try await api.deviceLiveToken()

        let requests = transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST"])
        XCTAssertEqual(requests.map { $0.url?.path }, ["/cameras/11111111-1111-4111-8111-111111111111/live-token", "/device/live-token"])
    }

    func testRealtimeRequestUsesWebSocketSchemeAndAuth() {
        let secure = DogMonitorAPI(baseURL: URL(string: "https://api.example.com")!, credential: .user(token: "jwt"))
        XCTAssertEqual(secure.realtimeRequest().url?.absoluteString, "wss://api.example.com/ws")
        XCTAssertEqual(secure.realtimeRequest().value(forHTTPHeaderField: "Authorization"), "Bearer jwt")

        let local = DogMonitorAPI(baseURL: URL(string: "http://localhost:3000")!)
        XCTAssertEqual(local.realtimeRequest().url?.absoluteString, "ws://localhost:3000/ws")
        XCTAssertNil(local.realtimeRequest().value(forHTTPHeaderField: "Authorization"))
    }
}
