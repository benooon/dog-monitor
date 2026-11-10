@preconcurrency import AVFoundation
import CoreImage
import DogMonitorCore
import ImageIO
import os
import UniformTypeIdentifiers

/// A clip or snapshot saved for an event, ready to upload.
struct RecordedMedia: Sendable, Equatable {
    let eventID: UUID
    let kind: MediaKind
    let url: URL
}

/// Ring-buffer recorder for event clips (SPEC §5).
///
/// Encodes the capture session's video (and audio) continuously with one `AVAssetWriter` that
/// emits ~1 s fragmented-MP4 segments in memory instead of writing a file. `ClipAssembler`
/// keeps the last ~5 s of segments; on `trigger(eventID:)` it collects 5 s before plus 10 s
/// after (20 s max), and the clip is saved as `<directory>/<eventID>/clip.mp4` (init segment +
/// media segments, playable by AVPlayer). The next video frame after a trigger becomes
/// `snapshot.jpg`. Saved files are announced on `media(...)`.
///
/// Video frames are not held: they go straight into the hardware encoder.
final class ClipRecorder: NSObject, @unchecked Sendable {
    static let fileRetention: TimeInterval = 2 * 24 * 3600

    private let directory: URL
    private let includeAudio: Bool
    private let broadcaster = Broadcaster<RecordedMedia>()
    private let logger = Logger(subsystem: "com.benooon.dogmonitor", category: "ClipRecorder")
    private let ioQueue = DispatchQueue(label: "com.benooon.dogmonitor.recorder.io", qos: .utility)
    private let ciContext = CIContext()

    // Everything below is guarded by `lock`. It is recursive because the writer may call its
    // delegate synchronously from inside `append`.
    private let lock = NSRecursiveLock()
    private var writer: AVAssetWriter?
    private var finishingWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var width = 0
    private var height = 0
    private var sessionStart: Double?
    private var initSegment: Data?
    private var assembler = ClipAssembler<Data>()
    private var lastVideoTime: Double?
    private var lastSegmentEnd: Double?
    private var audioSampleRate: Double = 44_100
    private var snapshotRequests: [UUID] = []
    private var isStopped = false

    init(directory: URL, includeAudio: Bool) {
        self.directory = directory
        self.includeAudio = includeAudio
        super.init()
        let directory = directory
        ioQueue.async { Self.pruneOldMedia(in: directory) }
    }

    func media(bufferingNewest limit: Int = 16) -> AsyncStream<RecordedMedia> {
        broadcaster.subscribe(bufferingNewest: limit)
    }

    /// Records until the streams end or the task is cancelled, then saves partial clips.
    func run(video: AsyncStream<CaptureSample>, audio: AsyncStream<CaptureSample>?) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await sample in video where sample.kind == .video {
                    self.handleVideo(sample)
                }
            }
            if let audio {
                group.addTask {
                    for await sample in audio where sample.kind == .audio {
                        self.handleAudio(sample)
                    }
                }
            }
        }
        stop()
    }

    /// Starts a clip and a snapshot for an event. Ignored before the first video frame.
    func trigger(eventID: UUID) {
        lock.withLock {
            guard !isStopped, let lastVideoTime else { return }
            assembler.trigger(id: eventID, at: lastVideoTime)
            snapshotRequests.append(eventID)
        }
    }

    /// Saves pending clips with what they have and stops encoding.
    func stop() {
        lock.withLock {
            guard !isStopped else { return }
            isStopped = true
            save(assembler.finishAll())
            tearDownWriter()
        }
    }

    // MARK: - Samples

    // Internal (not private) so tests can feed synthetic frames synchronously.
    func handleVideo(_ sample: CaptureSample) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample.buffer) else { return }
        let time = sample.presentationTime
        lock.withLock {
            guard !isStopped else { return }
            let newWidth = CVPixelBufferGetWidth(pixelBuffer)
            let newHeight = CVPixelBufferGetHeight(pixelBuffer)
            if writer == nil || newWidth != width || newHeight != height {
                // First frame, or the phone turned: segments of the old size cannot continue.
                save(assembler.finishAll())
                tearDownWriter()
                width = newWidth
                height = newHeight
                startWriter(at: sample.buffer)
            }
            if let videoInput, videoInput.isReadyForMoreMediaData, writer?.status == .writing {
                if !videoInput.append(sample.buffer) {
                    logger.error("Video append failed: \(String(describing: self.writer?.error), privacy: .public)")
                }
            }
            lastVideoTime = time
            if !snapshotRequests.isEmpty {
                let requests = snapshotRequests
                snapshotRequests = []
                saveSnapshot(of: pixelBuffer, for: requests)
            }
        }
    }

    private func handleAudio(_ sample: CaptureSample) {
        lock.withLock {
            guard !isStopped else { return }
            if writer == nil, let description = CMSampleBufferGetFormatDescription(sample.buffer),
               let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                // Remembered for the encoder settings when the writer starts on the first video frame.
                audioSampleRate = format.mSampleRate
            }
            guard let audioInput, let sessionStart, writer?.status == .writing,
                  sample.presentationTime >= sessionStart,
                  audioInput.isReadyForMoreMediaData
            else { return }
            _ = audioInput.append(sample.buffer)
        }
    }

    // MARK: - Writer (under lock)

    private func startWriter(at firstSample: CMSampleBuffer) {
        let start = CMSampleBufferGetPresentationTimeStamp(firstSample)
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.initialSegmentStartTime = start
        writer.delegate = self

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_000_000,
                // Segments start on key frames, so one per second keeps segments ~1 s.
                AVVideoMaxKeyFrameIntervalDurationKey: 1,
            ] as [String: Any],
        ])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else {
            logger.error("Cannot add video input")
            return
        }
        writer.add(video)

        var audio: AVAssetWriterInput?
        if includeAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audioSampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ])
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audio = input
            }
        }

        guard writer.startWriting() else {
            logger.error("Could not start writer: \(String(describing: writer.error), privacy: .public)")
            return
        }
        writer.startSession(atSourceTime: start)
        self.writer = writer
        videoInput = video
        audioInput = audio
        sessionStart = start.seconds
        lastSegmentEnd = nil
        initSegment = nil
    }

    private func tearDownWriter() {
        guard let writer else { return }
        self.writer = nil
        videoInput = nil
        audioInput = nil
        sessionStart = nil
        initSegment = nil
        lastSegmentEnd = nil
        if writer.status == .writing {
            // Kept alive until the next teardown; its final segment is ignored.
            finishingWriter = writer
            writer.finishWriting {}
        }
    }

    // MARK: - Saving

    private func save(_ clips: [AssembledClip<Data>]) {
        guard !clips.isEmpty, let initSegment else { return }
        for clip in clips {
            var data = initSegment
            for segment in clip.segments {
                data.append(segment.payload)
            }
            let url = mediaURL(for: clip.id, file: MediaKind.clip.fileName)
            let duration = clip.duration
            write(data, to: url, announcing: RecordedMedia(eventID: clip.id, kind: .clip, url: url)) { [logger] in
                logger.info("Saved \(duration, format: .fixed(precision: 1)) s clip")
            }
        }
    }

    private func saveSnapshot(of pixelBuffer: CVPixelBuffer, for eventIDs: [UUID]) {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = ciContext.jpegRepresentation(
                  of: image,
                  colorSpace: colorSpace,
                  options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7]
              )
        else {
            logger.error("Could not encode snapshot")
            return
        }
        for eventID in eventIDs {
            let url = mediaURL(for: eventID, file: MediaKind.snapshot.fileName)
            write(jpeg, to: url, announcing: RecordedMedia(eventID: eventID, kind: .snapshot, url: url)) {}
        }
    }

    private func mediaURL(for eventID: UUID, file: String) -> URL {
        directory
            .appendingPathComponent(eventID.uuidString, isDirectory: true)
            .appendingPathComponent(file)
    }

    private func write(_ data: Data, to url: URL, announcing media: RecordedMedia, then done: @escaping @Sendable () -> Void) {
        let broadcaster = broadcaster
        let logger = logger
        ioQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
                broadcaster.yield(media)
                done()
            } catch {
                logger.error("Could not save \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Deletes event folders older than `fileRetention` (uploads are expected long before).
    private static func pruneOldMedia(in directory: URL) {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date.now.addingTimeInterval(-fileRetention)
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: folder)
            }
        }
    }
}

extension ClipRecorder: AVAssetWriterDelegate {
    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        lock.withLock {
            guard writer === self.writer else { return }
            switch segmentType {
            case .initialization:
                initSegment = segmentData
            case .separable:
                guard let sessionStart else { return }
                let start = lastSegmentEnd ?? sessionStart
                let reported = segmentReport?.trackReports.first { $0.mediaType == .video }?.duration.seconds
                let duration: Double
                if let reported, reported.isFinite, reported > 0 {
                    duration = reported
                } else {
                    duration = max((lastVideoTime ?? start) - start, 0)
                }
                lastSegmentEnd = start + duration
                save(assembler.append(MediaSegment(start: start, duration: duration, payload: segmentData)))
            @unknown default:
                break
            }
        }
    }
}
