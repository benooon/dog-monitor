import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import DogMonitorCore

final class DailySummaryTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Jerusalem")!
        return calendar
    }()

    /// 2026-11-10 at `hour:minute` in Jerusalem (UTC+2 in November).
    private func local(_ hour: Int, _ minute: Int = 0, day: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func run(_ acc: inout DailySummaryAccumulator, state: DogState, moving: Bool, from start: Date, minutes: Int) {
        for second in 0...(minutes * 60) {
            acc.tick(state: state, moving: moving, at: start.addingTimeInterval(TimeInterval(second)), calendar: calendar)
        }
    }

    func testCountsStateMinutesActivityAndBarks() {
        var acc = DailySummaryAccumulator()
        run(&acc, state: .resting, moving: false, from: local(9), minutes: 30)
        run(&acc, state: .restless, moving: true, from: local(14, 10), minutes: 10)
        for _ in 0..<5 { acc.noteBark(at: local(14, 12), calendar: calendar) }

        let day = acc.summary(for: "2026-11-10")
        XCTAssertEqual(day.restMinutes, 30)
        XCTAssertEqual(day.minutes(in: .restless), 10)
        XCTAssertEqual(day.barkCount, 5)
        XCTAssertEqual(day.activityByHour.count, 24)
        XCTAssertEqual(day.activityByHour[14], 10)
        XCTAssertEqual(day.activityByHour[9], 0)
        XCTAssertEqual(day.busiestHour, 14)
    }

    func testGapsAreNotCounted() {
        var acc = DailySummaryAccumulator()
        acc.tick(state: .resting, moving: false, at: local(9), calendar: calendar)
        acc.tick(state: .resting, moving: false, at: local(11), calendar: calendar) // app was off
        XCTAssertEqual(acc.summary(for: "2026-11-10").restMinutes, 0)
    }

    func testSplitsAtLocalMidnightAndReportsPastDaysAsFinal() {
        var acc = DailySummaryAccumulator()
        run(&acc, state: .resting, moving: false, from: local(23, 50), minutes: 20)
        XCTAssertEqual(acc.summary(for: "2026-11-10").restMinutes, 10)
        XCTAssertEqual(acc.summary(for: "2026-11-11").restMinutes, 10)

        let pending = acc.pendingUploads(now: local(0, 10, day: 11), calendar: calendar)
        XCTAssertEqual(pending.map { $0.summary.date }, ["2026-11-10", "2026-11-11"])
        XCTAssertEqual(pending.map { $0.final }, [true, false])

        acc.markUploadedFinal("2026-11-10")
        XCTAssertEqual(acc.pendingUploads(now: local(0, 10, day: 11), calendar: calendar).map { $0.summary.date }, ["2026-11-11"])
    }

    func testDateKeyUsesTheCameraTimeZone() {
        // 23:30 UTC on Nov 10 is already Nov 11 in Jerusalem.
        let late = Date(timeIntervalSince1970: 1_794_353_400) // 2026-11-10T23:30:00Z
        XCTAssertEqual(DailySummaryAccumulator.dateKey(late, calendar: calendar), "2026-11-11")
    }

    func testSurvivesARestart() throws {
        var acc = DailySummaryAccumulator()
        run(&acc, state: .resting, moving: false, from: local(9), minutes: 3)
        let restored = try JSONDecoder().decode(DailySummaryAccumulator.self, from: JSONEncoder().encode(acc))
        XCTAssertEqual(restored.summary(for: "2026-11-10"), acc.summary(for: "2026-11-10"))
    }

    func testUploadAndListAPI() async throws {
        let json = """
        {"summaries":[{"cameraId":"\(Fixtures.deviceID)","date":"2026-11-10","restMinutes":30,"barkCount":5,
          "activityByHour":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,10,0,0,0,0,0,0,0,0,0],"stateMinutes":{"resting":30},
          "isFinal":false,"updatedAt":"2026-11-10T12:00:00.000Z"}]}
        """
        let stub = StubTransport(json: json)
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .user(token: "t"), transport: stub)
        let cameraId = try XCTUnwrap(UUID(uuidString: Fixtures.deviceID))

        let list = try await api.summaries(cameraId: cameraId, from: "2026-11-04")
        XCTAssertEqual(list.first?.summary.restMinutes, 30)
        XCTAssertEqual(list.first?.summary.busiestHour, 14)
        let url = try XCTUnwrap(stub.requests[0].url)
        XCTAssertEqual(url.path, "/v1/summaries")
        XCTAssertEqual(url.query, "cameraId=\(Fixtures.deviceID)&from=2026-11-04")

        let stub2 = StubTransport(json: #"{"cameraId":"\#(Fixtures.deviceID)","date":"2026-11-10","restMinutes":30,"barkCount":5,"activityByHour":[],"stateMinutes":{},"isFinal":true}"#)
        let camera = DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .device(id: cameraId, secret: "s"), transport: stub2)
        try await camera.uploadSummary(DailySummary(date: "2026-11-10", restMinutes: 30), final: true)
        let put = try XCTUnwrap(stub2.requests.first)
        XCTAssertEqual(put.url?.path, "/v1/device/summaries/2026-11-10")
        let body = try Fixtures.bodyJSON(put)
        XCTAssertEqual(body["final"] as? Bool, true)
        XCTAssertEqual((body["activityByHour"] as? [Int])?.count, 24)
    }
}
