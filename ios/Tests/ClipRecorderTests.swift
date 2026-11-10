import AVFoundation
import XCTest
@testable import DogMonitor

final class ClipRecorderTests: XCTestCase {
    /// Feeds 20 s of synthetic 10 fps video, triggers an event at 6 s, and expects a
    /// fragmented-MP4 clip and a JPEG snapshot on disk.
    func testSavesClipAndSnapshotForTrigger() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = ClipRecorder(directory: directory, includeAudio: false)
        let media = recorder.media()
        let eventID = UUID()

        for frame in 0..<200 {
            if frame == 60 { recorder.trigger(eventID: eventID) }
            let sample = try Self.videoSample(at: 100 + Double(frame) / 10)
            recorder.handleVideo(CaptureSample(kind: .video, buffer: sample))
            try await Task.sleep(for: .milliseconds(5))
        }

        let kinds = await Self.collectKinds(of: eventID, from: media, timeout: .seconds(10))
        // Whatever completed on its own, stopping saves the rest.
        recorder.stop()
        if kinds.count < 2 {
            try await Task.sleep(for: .seconds(1))
        }

        let snapshot = directory.appendingPathComponent(eventID.uuidString).appendingPathComponent("snapshot.jpg")
        let clip = directory.appendingPathComponent(eventID.uuidString).appendingPathComponent("clip.mp4")
        let jpeg = try Data(contentsOf: snapshot)
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
        let movie = try Data(contentsOf: clip)
        XCTAssertGreaterThan(movie.count, 8)
        XCTAssertEqual(String(decoding: movie[4..<8], as: UTF8.self), "ftyp")
    }

    func testTriggerBeforeFirstFrameIsIgnored() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = ClipRecorder(directory: directory, includeAudio: false)
        let eventID = UUID()
        recorder.trigger(eventID: eventID)
        recorder.stop()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(eventID.uuidString).path))
    }

    // MARK: - Helpers

    private static func collectKinds(
        of eventID: UUID,
        from media: AsyncStream<RecordedMedia>,
        timeout: Duration
    ) async -> Set<RecordedMedia.Kind> {
        await withTaskGroup(of: Set<RecordedMedia.Kind>?.self) { group in
            group.addTask {
                var kinds = Set<RecordedMedia.Kind>()
                for await item in media where item.eventID == eventID {
                    kinds.insert(item.kind)
                    if kinds.count == 2 { break }
                }
                return kinds
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    private static func videoSample(at seconds: Double) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, attributes, &pixelBuffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &format
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 10),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: try XCTUnwrap(format),
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        return try XCTUnwrap(sample)
    }
}
