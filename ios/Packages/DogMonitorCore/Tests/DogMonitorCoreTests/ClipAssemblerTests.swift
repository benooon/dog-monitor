import Foundation
import XCTest
@testable import DogMonitorCore

final class ClipAssemblerTests: XCTestCase {
    private typealias Assembler = ClipAssembler<Int>

    /// One-second segments whose payload is their start second.
    private func segment(_ second: Int) -> MediaSegment<Int> {
        MediaSegment(start: TimeInterval(second), duration: 1, payload: second)
    }

    private func feed(_ assembler: inout Assembler, _ seconds: ClosedRange<Int>) -> [AssembledClip<Int>] {
        var finished: [AssembledClip<Int>] = []
        for second in seconds {
            finished += assembler.append(segment(second))
        }
        return finished
    }

    func testRingKeepsOnlyThePreRoll() {
        var assembler = Assembler()
        XCTAssertTrue(feed(&assembler, 0...29).isEmpty)
        XCTAssertEqual(assembler.bufferedDuration, 5)
    }

    func testClipHasPreRollAndPostRoll() throws {
        var assembler = Assembler()
        _ = feed(&assembler, 0...29)
        let id = UUID()
        assembler.trigger(id: id, at: 30)
        XCTAssertEqual(assembler.pendingClipIDs, [id])

        let early = feed(&assembler, 30...38)
        XCTAssertTrue(early.isEmpty)
        let finished = feed(&assembler, 39...39)

        let clip = try XCTUnwrap(finished.first)
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(clip.id, id)
        XCTAssertEqual(clip.segments.map(\.payload), Array(25...39))
        XCTAssertEqual(clip.duration, 15)
        XCTAssertTrue(assembler.pendingClipIDs.isEmpty)
    }

    func testClipRightAfterStartHasShortPreRoll() throws {
        var assembler = Assembler()
        _ = feed(&assembler, 0...1)
        assembler.trigger(id: UUID(), at: 2)
        let clip = try XCTUnwrap(feed(&assembler, 2...20).first)
        XCTAssertEqual(clip.start, 0)
        XCTAssertEqual(clip.end, 12)
    }

    func testRepeatedTriggerIsIgnored() {
        var assembler = Assembler()
        let id = UUID()
        assembler.trigger(id: id, at: 0)
        assembler.trigger(id: id, at: 3)
        XCTAssertEqual(assembler.pendingClipIDs, [id])
        XCTAssertEqual(feed(&assembler, 0...20).count, 1)
    }

    func testOverlappingClipsShareSegments() {
        var assembler = Assembler()
        _ = feed(&assembler, 0...9)
        let first = UUID()
        let second = UUID()
        assembler.trigger(id: first, at: 10)
        _ = feed(&assembler, 10...12)
        assembler.trigger(id: second, at: 13)

        let finished = feed(&assembler, 13...30)
        XCTAssertEqual(finished.map(\.id), [first, second])
        XCTAssertEqual(finished[0].segments.map(\.payload), Array(5...19))
        XCTAssertEqual(finished[1].segments.map(\.payload), Array(8...22))
    }

    func testClipNeverExceedsMaxDuration() throws {
        // Long segments: the post-roll target would push the clip past the cap.
        var assembler = Assembler(configuration: .init(preRoll: 5, postRoll: 10, maxDuration: 12))
        _ = feed(&assembler, 0...9)
        assembler.trigger(id: UUID(), at: 10)
        let clip = try XCTUnwrap(feed(&assembler, 10...30).first)
        XCTAssertLessThanOrEqual(clip.duration, 12)
        XCTAssertEqual(clip.segments.map(\.payload), Array(5...16))
    }

    func testFinishAllReturnsPartialClipsAndClearsTheRing() throws {
        var assembler = Assembler()
        _ = feed(&assembler, 0...9)
        let id = UUID()
        assembler.trigger(id: id, at: 10)
        _ = feed(&assembler, 10...12)

        let finished = assembler.finishAll()
        let clip = try XCTUnwrap(finished.first)
        XCTAssertEqual(clip.id, id)
        XCTAssertEqual(clip.segments.map(\.payload), Array(5...12))
        XCTAssertTrue(assembler.pendingClipIDs.isEmpty)
        XCTAssertEqual(assembler.bufferedDuration, 0)
    }

    func testFinishAllSkipsClipsWithoutMedia() {
        var assembler = Assembler()
        assembler.trigger(id: UUID(), at: 0)
        XCTAssertTrue(assembler.finishAll().isEmpty)
    }
}
