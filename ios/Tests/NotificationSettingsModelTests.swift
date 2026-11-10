import DogMonitorCore
import XCTest
@testable import DogMonitor

/// Replies to every request with the same status and body, and records what was sent.
private final class CannedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int
    private let body: Data
    private var sent: [URLRequest] = []

    init(status: Int = 200, json: String) {
        self.status = status
        body = Data(json.utf8)
    }

    var requests: [URLRequest] { lock.withLock { sent } }

    func fail(with status: Int) {
        lock.withLock { self.status = status }
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock {
            sent.append(request)
            return HTTPResponse(statusCode: status, body: body)
        }
    }
}

@MainActor
final class NotificationSettingsModelTests: XCTestCase {
    private static let gone = "11111111-2222-4333-8444-555555555555"
    private static let json = """
    {"types":[{"eventType":"atDoor","enabledByDefault":false,"bypassesQuietHours":false}],
     "prefs":[{"cameraId":"\(gone)","eventType":"atDoor","enabled":true,"quietStart":null,"quietEnd":null}]}
    """

    private func makeModel(_ transport: CannedTransport) -> NotificationSettingsModel {
        let api = DogMonitorAPI(baseURL: URL(string: "https://api.example.com")!, credential: .user(token: "t"), transport: transport)
        return NotificationSettingsModel(api: api, cameras: [])
    }

    func testLoadsAndDropsCamerasThatLeftTheHousehold() async {
        let transport = CannedTransport(json: Self.json)
        let model = makeModel(transport)
        XCTAssertEqual(model.phase, .loading)

        await model.load()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(model.hasChanges)
        XCTAssertFalse(model.settings.isEnabled(.atDoor, camera: UUID(uuidString: Self.gone)!))
        XCTAssertEqual(transport.requests.first?.httpMethod, "GET")
    }

    func testLoadFailureShowsTheErrorState() async {
        let model = makeModel(CannedTransport(status: 500, json: #"{"error":"boom"}"#))
        await model.load()
        XCTAssertEqual(model.phase, .failed)
    }

    func testEditingAndSaving() async {
        let transport = CannedTransport(json: Self.json)
        let model = makeModel(transport)
        await model.load()

        model.settings.isQuietHoursOn = true
        XCTAssertTrue(model.hasChanges)

        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertFalse(model.saveFailed)
        XCTAssertEqual(transport.requests.last?.httpMethod, "PUT")
    }

    func testSaveFailureKeepsTheEditsAndRaisesTheAlert() async {
        let transport = CannedTransport(json: Self.json)
        let model = makeModel(transport)
        await model.load()
        model.settings[enabled: .dailySummary] = false
        transport.fail(with: 503)

        let saved = await model.save()

        XCTAssertFalse(saved)
        XCTAssertTrue(model.saveFailed)
        XCTAssertFalse(model.settings.isEnabled(.dailySummary))
        XCTAssertTrue(model.hasChanges)
    }

    func testQuietHoursDatesRoundTrip() throws {
        var settings = NotificationSettings(NotificationPrefsDTO(types: [], prefs: []))
        settings.isQuietHoursOn = true
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let evening = try XCTUnwrap(calendar.date(bySettingHour: 21, minute: 15, second: 0, of: .now))
        settings.quietStartDate = evening
        XCTAssertEqual(settings.quietHours?.start.wireValue, "21:15")
        XCTAssertEqual(settings.quietHours?.end, QuietHours.suggested.end)
        XCTAssertEqual(TimeOfDay(date: settings.quietStartDate).wireValue, "21:15")
    }
}
