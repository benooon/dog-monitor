import Foundation
import XCTest
@testable import DogMonitorCore

/// Replays simulated timelines through the engine. Time is seconds after `t0`.
final class EventEngineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var engine = EventEngine(cameraID: UUID())
    private var log: [(time: Double, output: EngineOutput)] = []

    override func setUp() {
        super.setUp()
        engine = EventEngine(cameraID: UUID())
        log = []
    }

    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    @discardableResult
    private func sound(_ kind: Detection.Kind, at seconds: Double, confidence: Double = 0.9) -> [EngineOutput] {
        let outputs = engine.ingest(Detection(kind: kind, confidence: confidence, timestamp: at(seconds)))
        log += outputs.map { (time: seconds, output: $0) }
        return outputs
    }

    /// One detection every `every` seconds from `from` through `through` (inclusive).
    private func sounds(_ kind: Detection.Kind, from: Double, through: Double, every: Double) {
        var t = from
        while t <= through {
            sound(kind, at: t)
            t += every
        }
    }

    @discardableResult
    private func see(_ state: DogState, at seconds: Double) -> [EngineOutput] {
        let outputs = engine.observe(state, at: at(seconds))
        log += outputs.map { (time: seconds, output: $0) }
        return outputs
    }

    private func seeing(_ state: DogState, from: Double, through: Double, every: Double = 1) {
        var t = from
        while t <= through {
            see(state, at: t)
            t += every
        }
    }

    @discardableResult
    private func tick(_ seconds: Double) -> [EngineOutput] {
        let outputs = engine.tick(now: at(seconds))
        log += outputs.map { (time: seconds, output: $0) }
        return outputs
    }

    private func started(_ type: EventType) -> [(time: Double, event: DogEvent)] {
        log.compactMap { entry -> (time: Double, event: DogEvent)? in
            if case .started(let event) = entry.output, event.type == type { return (time: entry.time, event: event) }
            return nil
        }
    }

    private func outputs(_ type: EventType) -> [EngineOutput] {
        log.map { $0.output }.filter { $0.event.type == type }
    }

    // MARK: - Barking thresholds

    func testIsolatedBarksDoNotFire() {
        sound(.bark, at: 0)
        sound(.bark, at: 20)
        sound(.bark, at: 40)
        tick(600)
        XCTAssertTrue(started(.prolongedBarking).isEmpty)
        XCTAssertTrue(started(.calmedDown).isEmpty, "no calm without an alert")
    }

    func testSustainedBarkingFiresAfterMinDuration() {
        // Barks every 3 s: 5 hits by t=12 (below the count rule), duration reaches 10 s at t=12.
        sounds(.bark, from: 0, through: 9, every: 3)
        XCTAssertTrue(started(.prolongedBarking).isEmpty)
        sound(.bark, at: 12)
        let fired = started(.prolongedBarking)
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired.first?.time, 12)
        XCTAssertEqual(fired.first?.event.startedAt, at(0))
        XCTAssertEqual(fired.first?.event.state, .barking)
        XCTAssertEqual(engine.currentState(at: at(12)), .barking)
        XCTAssertEqual(engine.activeEvents.count, 1)
    }

    func testBurstOfBarksFiresByCount() {
        sounds(.bark, from: 0, through: 2.5, every: 0.5) // 6 barks in 2.5 s
        XCTAssertEqual(started(.prolongedBarking).map { $0.time }, [2.5])
    }

    func testIntermittentBarksWithinAMinuteFireByCount() {
        // Gaps of 11 s end each episode, but 6 barks within 60 s still count.
        for t in stride(from: 0.0, through: 55, by: 11) { sound(.bark, at: t) }
        let fired = started(.prolongedBarking)
        XCTAssertEqual(fired.map { $0.time }, [55])
        XCTAssertEqual(fired.first?.event.startedAt, at(0))
    }

    func testFiresOnlyOncePerEpisode() {
        sounds(.bark, from: 0, through: 120, every: 2)
        XCTAssertEqual(started(.prolongedBarking).count, 1)
    }

    func testLowConfidenceAndNonDogSoundsAreIgnored() {
        var t = 0.0
        while t <= 30 {
            sound(.bark, at: t, confidence: 0.5)
            sound(.loudNoise, at: t + 0.5)
            t += 1
        }
        XCTAssertTrue(log.isEmpty)
        XCTAssertNotEqual(engine.currentState(at: at(30)), .barking)
    }

    func testGrowlCountsAsBarking() {
        sounds(.growl, from: 0, through: 12, every: 3)
        XCTAssertEqual(started(.prolongedBarking).count, 1)
    }

    // MARK: - Episode end, escalation, cooldown, calm

    func testEpisodeEndsAfterGapTolerance() {
        sounds(.bark, from: 0, through: 12, every: 3)
        XCTAssertTrue(tick(20).isEmpty, "8 s gap is still within tolerance")
        let outputs = tick(20.5)
        guard case .ended(let event)? = outputs.first else { return XCTFail("expected .ended, got \(outputs)") }
        XCTAssertEqual(event.endedAt, at(12))
        XCTAssertEqual(event.duration(now: at(999)), 12)
        XCTAssertTrue(engine.activeEvents.isEmpty)
        XCTAssertNotEqual(engine.currentState(at: at(20.5)), .barking)
    }

    func testEscalatesAtFiveAndFifteenMinutesOnce() {
        sounds(.bark, from: 0, through: 960, every: 3)
        let escalations = outputs(.prolongedBarking).compactMap { output -> TimeInterval? in
            if case .escalated(_, let duration) = output { return duration }
            return nil
        }
        XCTAssertEqual(escalations, [300, 900])
        XCTAssertEqual(started(.prolongedBarking).count, 1)
    }

    func testBarkingAgainWithinCooldownContinuesTheSameEvent() {
        sounds(.bark, from: 0, through: 12, every: 3)
        tick(30) // ended at 12
        sounds(.bark, from: 60, through: 72, every: 3)

        XCTAssertEqual(started(.prolongedBarking).count, 1, "no second push within cooldown")
        let resumed = outputs(.prolongedBarking).compactMap { output -> DogEvent? in
            if case .resumed(let event) = output { return event }
            return nil
        }
        XCTAssertEqual(resumed.count, 1)
        XCTAssertEqual(resumed.first?.id, started(.prolongedBarking).first?.event.id)
        XCTAssertNil(resumed.first?.endedAt)
        XCTAssertEqual(resumed.first?.startedAt, at(0))
    }

    func testBarkingAfterCooldownStartsANewEvent() {
        sounds(.bark, from: 0, through: 12, every: 3)
        tick(30)
        // Make sure calm does not interfere: whatever happens, after > 5 min a new event starts.
        sounds(.bark, from: 400, through: 412, every: 3)
        let fired = started(.prolongedBarking)
        XCTAssertEqual(fired.count, 2)
        XCTAssertNotEqual(fired[0].event.id, fired[1].event.id)
        XCTAssertEqual(fired[1].event.startedAt, at(400))
    }

    func testCalmedDownAfterQuietPeriod() {
        sounds(.bark, from: 0, through: 12, every: 3)
        tick(30)
        XCTAssertTrue(tick(131).filter { $0.event.type == .calmedDown }.isEmpty, "119 s of quiet is not enough")
        let calm = tick(132)
        XCTAssertEqual(calm.count, 1)
        guard case .started(let event)? = calm.first else { return XCTFail("expected calmedDown") }
        XCTAssertEqual(event.type, .calmedDown)
        XCTAssertEqual(event.state, .resting)
        XCTAssertFalse(event.isOngoing)
        tick(500)
        XCTAssertEqual(started(.calmedDown).count, 1, "calm is sent once per alert")
    }

    func testWhenTheCameraSeesTheDogCalmWaitsForRest() {
        sounds(.bark, from: 0, through: 12, every: 3)
        seeing(.restless, from: 13, through: 200, every: 5)
        XCTAssertTrue(started(.calmedDown).isEmpty, "quiet but still restless is not calm")
        seeing(.resting, from: 205, through: 215, every: 5)
        XCTAssertEqual(started(.calmedDown).count, 1)
        XCTAssertEqual(started(.calmedDown).first?.time, 210, "on the first tick after resting was seen")
    }

    func testStaleVisionFallsBackToQuietAlone() {
        sounds(.bark, from: 0, through: 12, every: 3)
        see(.restless, at: 20) // then the vision pipeline goes quiet (no motion, nothing new)
        XCTAssertTrue(tick(100).filter { $0.event.type == .calmedDown }.isEmpty)
        XCTAssertEqual(tick(140).filter { $0.event.type == .calmedDown }.count, 1, "last look is over 60 s old")
    }

    func testBarkingAfterCalmIsANewPushEvenWithinCooldown() {
        sounds(.bark, from: 0, through: 12, every: 3)
        tick(30)
        tick(140) // calmed down
        sounds(.bark, from: 200, through: 212, every: 3) // < 5 min after the first event ended
        XCTAssertEqual(started(.prolongedBarking).count, 2)
    }

    func testShortBarkDelaysCalm() {
        sounds(.bark, from: 0, through: 12, every: 3)
        tick(30)
        sound(.bark, at: 100) // one bark, not an event
        tick(140)
        XCTAssertTrue(started(.calmedDown).isEmpty)
        tick(220)
        XCTAssertEqual(started(.calmedDown).map { $0.time }, [220])
    }

    // MARK: - Whining

    func testWhiningIsSeparateFromBarking() {
        sounds(.whimper, from: 0, through: 15, every: 3)
        sound(.howl, at: 18)
        XCTAssertEqual(started(.whining).count, 1)
        XCTAssertEqual(started(.whining).first?.event.state, .whining)
        XCTAssertTrue(started(.prolongedBarking).isEmpty)
        XCTAssertEqual(engine.currentState(at: at(18)), .whining)
    }

    func testBarkingWinsCurrentState() {
        sounds(.whimper, from: 0, through: 6, every: 3)
        sound(.bark, at: 7)
        XCTAssertEqual(engine.currentState(at: at(7)), .barking)
    }

    // MARK: - Visual states

    func testAtDoorFiresAfterThirtySecondsAndEndsWhenTheDogLeaves() {
        seeing(.atDoor, from: 0, through: 29)
        XCTAssertTrue(started(.atDoor).isEmpty)
        see(.atDoor, at: 30)
        XCTAssertEqual(started(.atDoor).map { $0.time }, [30])
        XCTAssertEqual(engine.currentState(at: at(30)), .atDoor)

        seeing(.resting, from: 31, through: 45)
        XCTAssertEqual(engine.currentState(at: at(45)), .resting)
        let ended = outputs(.atDoor).compactMap { output -> DogEvent? in
            if case .ended(let event) = output { return event }
            return nil
        }
        XCTAssertEqual(ended.first?.endedAt, at(30))
        XCTAssertTrue(started(.calmedDown).isEmpty, "calm is only for barking/whining")
    }

    func testBriefForbiddenZoneVisitDoesNotFire() {
        seeing(.forbiddenZone, from: 0, through: 3)
        seeing(.resting, from: 4, through: 30)
        XCTAssertTrue(started(.forbiddenZone).isEmpty)
        seeing(.forbiddenZone, from: 40, through: 46)
        XCTAssertEqual(started(.forbiddenZone).map { $0.time }, [45])
    }

    func testNotVisibleNeedsTenMinutes() {
        seeing(.notVisible, from: 0, through: 599, every: 10)
        XCTAssertTrue(started(.notVisible).isEmpty)
        see(.notVisible, at: 600)
        XCTAssertEqual(started(.notVisible).count, 1)
    }

    func testConfigurationIsAdjustable() {
        var config = EventEngineConfiguration.default
        config.barking.minDuration = 30
        config.barking.countThreshold = nil
        engine = EventEngine(cameraID: UUID(), configuration: config)
        sounds(.bark, from: 0, through: 27, every: 1)
        XCTAssertTrue(started(.prolongedBarking).isEmpty)
        sound(.bark, at: 30)
        XCTAssertEqual(started(.prolongedBarking).count, 1)
    }

    func testEventsCarryCameraAndPeakConfidence() {
        let camera = UUID()
        engine = EventEngine(cameraID: camera)
        sound(.bark, at: 0, confidence: 0.75)
        sound(.bark, at: 3, confidence: 0.95)
        sounds(.bark, from: 6, through: 12, every: 3)
        let event = started(.prolongedBarking).first?.event
        XCTAssertEqual(event?.cameraID, camera)
        XCTAssertEqual(event?.confidence ?? 0, 0.95, accuracy: 0.0001)
    }
}
