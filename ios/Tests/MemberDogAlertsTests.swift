import DogMonitorCore
import XCTest
@testable import DogMonitor

/// Replies in order and records what was sent.
private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
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
final class MemberDogAlertsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        let suite = "MemberDogAlertsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
    }

    private static var prefs: String {
        let types = EventType.allCases.map {
            #"{"eventType":"\#($0.rawValue)","enabledByDefault":\#($0.isEnabledByDefault),"bypassesQuietHours":false}"#
        }
        return #"{"types":[\#(types.joined(separator: ","))],"prefs":[]}"#
    }

    private func household(role: MemberRole, alertStyle: DogAlertStyle?) -> HouseholdDTO {
        let id = UUID()
        let dog = DogDTO(id: UUID(), householdId: id, name: "Rex", traits: [.waitsAtDoor], alertStyle: alertStyle, createdAt: .now)
        return HouseholdDTO(id: id, name: "Home", ownerId: UUID(), role: role, members: [], dogs: [dog], devices: [])
    }

    private func api(_ transport: RecordingTransport) -> DogMonitorAPI {
        DogMonitorAPI(baseURL: URL(string: "https://api.example.com")!, transport: transport)
    }

    func testAMemberGetsTheDogsAlertsOnce() async throws {
        let transport = RecordingTransport([(200, Self.prefs), (200, Self.prefs)])
        let home = household(role: .member, alertStyle: .balanced)

        let first = await MemberDogAlerts.applyIfNeeded(household: home, api: api(transport), defaults: defaults)
        XCTAssertEqual(first?.name, "Rex")
        XCTAssertEqual(transport.requests.map(\.httpMethod), ["GET", "PUT"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(transport.requests[1].httpBody)) as? [String: Any])
        let prefs = try XCTUnwrap(body["prefs"] as? [[String: Any]])
        let atDoor = prefs.first { $0["eventType"] as? String == "atDoor" }
        XCTAssertEqual(atDoor?["enabled"] as? Bool, true)

        let second = await MemberDogAlerts.applyIfNeeded(household: home, api: api(transport), defaults: defaults)
        XCTAssertNil(second)
        XCTAssertEqual(transport.requests.count, 2, "never applied twice")
    }

    func testOwnersAndDogsWithoutAProfileAreLeftAlone() async {
        let transport = RecordingTransport([])
        let owner = await MemberDogAlerts.applyIfNeeded(
            household: household(role: .owner, alertStyle: .balanced), api: api(transport), defaults: defaults
        )
        let noProfile = await MemberDogAlerts.applyIfNeeded(
            household: household(role: .member, alertStyle: nil), api: api(transport), defaults: defaults
        )
        XCTAssertNil(owner)
        XCTAssertNil(noProfile)
        XCTAssertEqual(transport.requests.count, 0)
    }

    func testAFailureIsTriedAgain() async {
        let transport = RecordingTransport([(500, "{}"), (200, Self.prefs), (200, Self.prefs)])
        let home = household(role: .member, alertStyle: .important)
        let failed = await MemberDogAlerts.applyIfNeeded(household: home, api: api(transport), defaults: defaults)
        XCTAssertNil(failed)
        XCTAssertFalse(MemberDogAlerts.isApplied(householdId: home.id, defaults: defaults))
        let retried = await MemberDogAlerts.applyIfNeeded(household: home, api: api(transport), defaults: defaults)
        XCTAssertNotNil(retried)
    }
}
