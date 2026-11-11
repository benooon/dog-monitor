import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import DogMonitorCore

final class HighlightReelTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_794_268_800) // 2026-11-10T00:00:00Z
    private let planner = HighlightReelPlanner()

    private func clip(
        _ type: EventType,
        place: String? = nil,
        hour: Double,
        duration: TimeInterval = 15,
        confidence: Double = 0.8
    ) -> ReelCandidate {
        ReelCandidate(
            eventID: UUID(),
            type: type,
            place: place,
            startedAt: day.addingTimeInterval(hour * 3600),
            clipDuration: duration,
            confidence: confidence
        )
    }

    func testNeedsAtLeastThreeMoments() {
        XCTAssertNil(planner.plan([]))
        XCTAssertNil(planner.plan([clip(.atDoor, hour: 9), clip(.prolongedBarking, hour: 10)]))
        // System events and too-short clips don't count.
        XCTAssertNil(planner.plan([
            clip(.atDoor, hour: 9), clip(.prolongedBarking, hour: 10),
            clip(.cameraOffline, hour: 11), clip(.whining, hour: 12, duration: 2),
        ]))
    }

    func testThreeMomentsMakeAReelInTimeOrderWithinTwentyToThirtySeconds() throws {
        let sofa = clip(.forbiddenZone, place: "sofa", hour: 14)
        let door = clip(.atDoor, hour: 17)
        let bark = clip(.prolongedBarking, hour: 9)
        let segments = try XCTUnwrap(planner.plan([sofa, door, bark]))
        XCTAssertEqual(segments.map(\.eventID), [bark.eventID, sofa.eventID, door.eventID])
        XCTAssertEqual(segments.map(\.duration), [8, 8, 8])
        XCTAssertEqual(segments.map(\.start), [3, 3, 3])
        let total = planner.duration(of: segments)
        XCTAssertGreaterThanOrEqual(total, 20)
        XCTAssertLessThanOrEqual(total, 30)
    }

    func testPicksTheBestFiveWithVariety() throws {
        let sofa1 = clip(.forbiddenZone, place: "sofa", hour: 10)
        let sofa2 = clip(.forbiddenZone, place: "sofa", hour: 13)
        let sofa3 = clip(.forbiddenZone, place: "sofa", hour: 15)
        let door = clip(.atDoor, hour: 17)
        let bark1 = clip(.prolongedBarking, hour: 11, confidence: 0.95)
        let bark2 = clip(.prolongedBarking, hour: 11.05, confidence: 0.9) // same episode as bark1
        let bark3 = clip(.prolongedBarking, hour: 16, confidence: 0.6)
        let whine = clip(.whining, hour: 8)

        let segments = try XCTUnwrap(planner.plan([sofa1, sofa2, sofa3, door, bark1, bark2, bark3, whine]))
        let ids = Set(segments.map(\.eventID))
        XCTAssertEqual(segments.count, 5)
        // Two sofas at most, the door, and two barks from different episodes; whining loses out.
        XCTAssertEqual(ids, [sofa1.eventID, sofa2.eventID, door.eventID, bark1.eventID, bark3.eventID])
        let total = planner.duration(of: segments)
        XCTAssertGreaterThanOrEqual(total, 20)
        XCTAssertLessThanOrEqual(total, 30)
    }

    func testShortClipsKeepTheirLengthAndStartInside() throws {
        let segments = try XCTUnwrap(planner.plan([
            clip(.atDoor, hour: 9, duration: 5),
            clip(.forbiddenZone, place: "offLimits", hour: 10, duration: 20),
            clip(.whining, hour: 11, duration: 6),
        ]))
        XCTAssertEqual(segments[0].duration, 5)
        XCTAssertEqual(segments[0].start, 0)
        XCTAssertEqual(segments[2].duration, 6)
        XCTAssertEqual(segments[2].start, 0)
        for segment in segments {
            XCTAssertGreaterThanOrEqual(segment.start, 0)
        }
    }

    func testMoments() {
        XCTAssertEqual(clip(.forbiddenZone, place: "sofa", hour: 1).moment, .sofa)
        XCTAssertEqual(clip(.forbiddenZone, hour: 1).moment, .offLimits)
        XCTAssertEqual(clip(.atDoor, hour: 1).moment, .door)
        XCTAssertNil(clip(.dailySummary, hour: 1).moment)
    }

    func testLibraryKeepsADayAndAHalfAndAtMostSixty() {
        var library = ReelClipLibrary()
        let old = clip(.atDoor, hour: 0)
        library.add(old, now: day)
        library.add(old, now: day)
        XCTAssertEqual(library.clips.count, 1)

        let later = day.addingTimeInterval(37 * 3600)
        let fresh = clip(.whining, hour: 30)
        XCTAssertEqual(library.add(fresh, now: later), [old.eventID])
        XCTAssertEqual(library.clips.map(\.eventID), [fresh.eventID])

        var full = ReelClipLibrary()
        var dropped: [UUID] = []
        for minute in 0..<61 {
            dropped += full.add(clip(.prolongedBarking, hour: Double(minute) / 60), now: day.addingTimeInterval(3600))
        }
        XCTAssertEqual(full.clips.count, ReelClipLibrary.maxCount)
        XCTAssertEqual(dropped.count, 1)
    }

    func testLibraryFiltersByLocalDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Jerusalem")) // UTC+2 in November
        var library = ReelClipLibrary()
        let lateUTC = clip(.atDoor, hour: 23) // 01:00 on 11 Nov in Jerusalem
        let morning = clip(.atDoor, hour: 8)
        library.add(lateUTC, now: day.addingTimeInterval(24 * 3600))
        library.add(morning, now: day.addingTimeInterval(24 * 3600))
        XCTAssertEqual(library.clipsRecorded(on: "2026-11-10", calendar: calendar).map(\.eventID), [morning.eventID])
        XCTAssertEqual(library.clipsRecorded(on: "2026-11-11", calendar: calendar).map(\.eventID), [lateUTC.eventID])
    }

    func testReelAPI() async throws {
        let cameraId = try XCTUnwrap(UUID(uuidString: Fixtures.deviceID))
        let upload = StubTransport(json: #"{"upload":{"key":"households/h/cameras/c/reels/2026-11-10.mp4","url":"https://bucket.test/r?put","headers":{"Content-Type":"video/mp4"},"expiresAt":"2026-11-11T00:15:00.000Z"}}"#)
        let camera = DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .device(id: cameraId, secret: "s"), transport: upload)
        let target = try await camera.requestReelUpload(date: "2026-11-10")
        XCTAssertEqual(target.headers["Content-Type"], "video/mp4")
        XCTAssertEqual(upload.requests.first?.httpMethod, "POST")
        XCTAssertEqual(upload.requests.first?.url?.path, "/v1/device/reels/2026-11-10/upload")
        XCTAssertNil(upload.requests.first?.httpBody)

        let attach = StubTransport(json: #"{"hasReel":true}"#)
        try await DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .device(id: cameraId, secret: "s"), transport: attach)
            .attachReel(date: "2026-11-10")
        XCTAssertEqual(attach.requests.first?.httpMethod, "PUT")
        XCTAssertEqual(attach.requests.first?.url?.path, "/v1/device/reels/2026-11-10")

        let download = StubTransport(json: #"{"url":"https://bucket.test/r?get","expiresAt":"2026-11-11T00:10:00.000Z"}"#)
        let reel = try await DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .user(token: "t"), transport: download)
            .reel(cameraId: cameraId, date: "2026-11-10")
        XCTAssertEqual(reel.url.absoluteString, "https://bucket.test/r?get")
        XCTAssertEqual(download.requests.first?.url?.path, "/v1/summaries/\(Fixtures.deviceID.lowercased())/2026-11-10/reel")
    }

    func testSummaryDecodesHasReel() throws {
        let json = #"{"cameraId":"\#(Fixtures.deviceID)","date":"2026-11-10","restMinutes":30,"barkCount":5,"activityByHour":[],"stateMinutes":{},"isFinal":true,"hasReel":true}"#
        let summary = try JSONCoding.makeDecoder().decode(DailySummaryDTO.self, from: Data(json.utf8))
        XCTAssertEqual(summary.hasReel, true)
        let older = #"{"cameraId":"\#(Fixtures.deviceID)","date":"2026-11-10","restMinutes":30,"barkCount":5,"activityByHour":[],"stateMinutes":{},"isFinal":true}"#
        XCTAssertNil(try JSONCoding.makeDecoder().decode(DailySummaryDTO.self, from: Data(older.utf8)).hasReel)
    }
}
