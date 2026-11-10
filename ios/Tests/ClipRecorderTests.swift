import AVFoundation
import DogMonitorCore
import XCTest
@testable import DogMonitor

final class ClipRecorderTests: XCTestCase {
    /// Feeds 20 s of synthetic 10 fps video, triggers an event at 6 s, and expects a
    /// fragmented-MP4 clip and a JPEG snapshot on disk.
    func testSavesClipAndSnapshotForTrigger() async throws {
        let directory = try makeDirectory()
        let recorder = makeRecorder(in: directory)
        let media = recorder.media()
        let eventID = UUID()

        for frame in 0..<200 {
            if frame == 60 { recorder.trigger(eventID: eventID) }
            let sample = try Self.videoSample(at: 100 + Double(frame) / 10)
            recorder.handleVideo(CaptureSample(kind: .video, buffer: sample))
            try await Task.sleep(for: .milliseconds(5))
        }

        _ = await Self.collectKinds(of: eventID, from: media, timeout: .seconds(10))
        // Whatever completed on its own, stopping saves the rest. Waiting for the write queue
        // (instead of sleeping) means every save has finished before we read or clean up.
        recorder.stop()
        await recorder.waitForPendingWrites()

        let folder = directory.appendingPathComponent(eventID.uuidString, isDirectory: true)
        let jpeg = try XCTUnwrap(
            FileManager.default.contents(atPath: folder.appendingPathComponent("snapshot.jpg").path),
            "snapshot.jpg was not saved"
        )
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
        let movie = try XCTUnwrap(
            FileManager.default.contents(atPath: folder.appendingPathComponent("clip.mp4").path),
            "clip.mp4 was not saved"
        )
        XCTAssertGreaterThan(movie.count, 8)
        guard movie.count > 8 else { return }
        XCTAssertEqual(String(decoding: movie[4..<8], as: UTF8.self), "ftyp")
    }

    func testTriggerBeforeFirstFrameIsIgnored() async throws {
        let directory = try makeDirectory()
        let recorder = makeRecorder(in: directory)
        let eventID = UUID()
        recorder.trigger(eventID: eventID)
        recorder.stop()
        await recorder.waitForPendingWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(eventID.uuidString).path))
    }

    // MARK: - Helpers

    /// A fresh folder per test, created up front so the recorder's pruning and writes never
    /// race its creation.
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipRecorderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Cleanup runs after the recorder is stopped and its write queue has drained, so the
    /// folder is never removed while a save (or an atomic write's temporary file) is in flight.
    private func makeRecorder(in directory: URL) -> ClipRecorder {
        let recorder = ClipRecorder(directory: directory, includeAudio: false)
        addTeardownBlock {
            recorder.stop()
            await recorder.waitForPendingWrites()
            try? FileManager.default.removeItem(at: directory)
        }
        return recorder
    }

    private static func collectKinds(
        of eventID: UUID,
        from media: AsyncStream<RecordedMedia>,
        timeout: Duration
    ) async -> Set<MediaKind> {
        await withTaskGroup(of: Set<MediaKind>?.self) { group in
            group.addTask {
                var kinds = Set<MediaKind>()
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
