import DogMonitorCore
import XCTest
@testable import DogMonitor

/// Answers every request with one status and body, and records the requests.
private final class SummaryTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let status: Int
    private let body: Data
    private var sent: [URLRequest] = []

    init(status: Int = 200, json: String) {
        self.status = status
        body = Data(json.utf8)
    }

    var requests: [URLRequest] { lock.withLock { sent } }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock {
            sent.append(request)
            return HTTPResponse(statusCode: status, body: body)
        }
    }
}

@MainActor
final class DailySummaryModelTests: XCTestCase {
    private static let kitchen = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let hall = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    private static func day(_ camera: UUID, _ date: String, barks: Int) -> String {
        let hours = Array(repeating: "0", count: 24).joined(separator: ",")
        return """
        {"cameraId":"\(camera.uuidString.lowercased())","date":"\(date)","restMinutes":60,"barkCount":\(barks),
         "activityByHour":[\(hours)],"stateMinutes":{"resting":60},"isFinal":true,"updatedAt":"2026-11-10T10:00:00.000Z"}
        """
    }

    private static let json = """
    {"summaries":[\(day(kitchen, "2026-11-10", barks: 3)),\(day(kitchen, "2026-11-09", barks: 8)),\(day(hall, "2026-11-10", barks: 1))]}
    """

    private func makeModel(_ transport: SummaryTransport) -> DailySummaryModel {
        let api = DogMonitorAPI(baseURL: URL(string: "https://api.example.com")!, credential: .user(token: "t"), transport: transport)
        return DailySummaryModel(api: api, cameras: [], cameraId: Self.kitchen)
    }

    func testLoadsRecentDaysAndShowsTheChosenCamera() async throws {
        let transport = SummaryTransport(json: Self.json)
        let model = makeModel(transport)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Jerusalem")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!

        await model.load(now: now, calendar: calendar)

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.dates, ["2026-11-10", "2026-11-09"])
        XCTAssertEqual(model.insights.day?.barkCount, 3)
        XCTAssertEqual(model.insights.barkChange, -5)
        // The plan and sofa alerts load alongside; this stub can't answer them, so no weekly section.
        let url = try XCTUnwrap(transport.requests.compactMap(\.url).first { $0.path == "/summaries" })
        XCTAssertEqual(url.query, "from=2026-10-11")
        XCTAssertNil(model.insightsUnlocked)
    }

    func testSwitchingCameraShowsItsNewestDay() async {
        let model = makeModel(SummaryTransport(json: Self.json))
        await model.load()
        model.selectedDate = "2026-11-09"
        XCTAssertEqual(model.insights.day?.barkCount, 8)

        model.cameraId = Self.hall

        XCTAssertNil(model.selectedDate)
        XCTAssertEqual(model.insights.day?.barkCount, 1)
        XCTAssertNil(model.insights.previousDay)
    }

    func testFailureShowsTheErrorState() async {
        let model = makeModel(SummaryTransport(status: 500, json: #"{"error":"boom"}"#))
        await model.load()
        XCTAssertEqual(model.phase, .failed)
    }

    func testReelPreviewShowsTheReelDayAndUsesTheCachedFile() async throws {
        let model = DailySummaryModel.preview(reelOnDaysAgo: 1)
        let summary = try XCTUnwrap(model.selectedSummary)
        XCTAssertEqual(summary.hasReel, true)
        XCTAssertTrue(summary.isFinal)

        // The screenshot test relies on this fixture; a cached file is returned without the network.
        let sample = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample-reel", withExtension: "mp4"))
        let target = DailySummaryModel.reelCacheURL(for: summary)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: sample, to: target)
        defer { try? FileManager.default.removeItem(at: target) }

        let file = try await model.reelFile(for: summary)
        XCTAssertEqual(file, target)
    }

    func testSofaVisitsAreGroupedByCameraAndOnlySofa() {
        func event(_ camera: UUID?, _ type: EventType, place: String?, minutesAgo: Double) -> EventDTO {
            EventDTO(
                id: UUID(),
                householdId: UUID(),
                cameraId: camera,
                type: type,
                startedAt: Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60),
                place: place
            )
        }
        let visits = DailySummaryModel.sofaVisits(in: [
            event(Self.kitchen, .forbiddenZone, place: "sofa", minutesAgo: 10),
            event(Self.kitchen, .forbiddenZone, place: "offLimits", minutesAgo: 20),
            event(Self.hall, .forbiddenZone, place: "sofa", minutesAgo: 30),
            event(Self.hall, .atDoor, place: nil, minutesAgo: 40),
            event(nil, .forbiddenZone, place: "sofa", minutesAgo: 50),
        ])
        XCTAssertEqual(visits[Self.kitchen]?.count, 1)
        XCTAssertEqual(visits[Self.hall]?.count, 1)
        XCTAssertEqual(visits.count, 2)
    }
}
