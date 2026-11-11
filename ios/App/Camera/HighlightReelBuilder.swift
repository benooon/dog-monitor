import AVFoundation
import CoreText
import DogMonitorCore
import Foundation
import QuartzCore
import os

/// The camera's side of the daily highlight reel (Premium): keeps a copy of each event clip
/// (the media uploader deletes its own after upload), and once a day is final stitches the best
/// moments into a vertical video with a small "Dog Monitor" end card and uploads it.
///
/// What goes in the reel is decided by `HighlightReelPlanner` in DogMonitorCore; this type only
/// copies files and runs AVFoundation.
actor HighlightReelBuilder {
    /// What the camera knows about an event when its clip is saved.
    struct EventInfo: Sendable {
        var type: EventType
        var place: String?
        var startedAt: Date
        var confidence: Double
    }

    private struct State: Codable {
        var library = ReelClipLibrary()
        /// Final days whose reel is still to be made or uploaded.
        var pendingDates: [String] = []
    }

    private let directory: URL
    private let stateURL: URL
    private var state: State
    private var isWorking = false
    private let logger = Logger(subsystem: "com.benooon.dogmonitor", category: "reel")

    init(directory: URL = HighlightReelBuilder.defaultDirectory) {
        let stateURL = directory.appendingPathComponent("reel-state.json")
        self.directory = directory
        self.stateURL = stateURL
        state = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("highlight-reel", isDirectory: true)
    }

    /// Copies a freshly saved clip so it is still here at the end of the day.
    func keep(clipAt source: URL, eventID: UUID, info: EventInfo) async {
        let destination = clipURL(eventID)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            logger.error("Could not keep clip for the reel: \(error.localizedDescription, privacy: .public)")
            return
        }
        let duration = (try? await AVURLAsset(url: destination).load(.duration).seconds) ?? 0
        let candidate = ReelCandidate(
            eventID: eventID,
            type: info.type,
            place: info.place,
            startedAt: info.startedAt,
            clipDuration: duration.isFinite ? duration : 0,
            confidence: info.confidence
        )
        removeClips(state.library.add(candidate, now: .now))
        save()
    }

    /// A day's summary was uploaded as final: its reel can be made now.
    func dayFinished(_ date: String) {
        guard !state.pendingDates.contains(date) else { return }
        state.pendingDates.append(date)
        save()
    }

    /// Makes and uploads the reels of finished days. Stops at the first failure that a later try
    /// could fix (offline, the summary not stored yet); days that can't have a reel are dropped.
    func uploadPending(using api: DogMonitorAPI, calendar: Calendar) async {
        guard !isWorking, !state.pendingDates.isEmpty else { return }
        // Exporting a video next to live capture heats the phone; wait until it cools down.
        guard ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue else { return }
        isWorking = true
        defer { isWorking = false }

        removeClips(state.library.prune(now: .now))
        for date in state.pendingDates {
            switch await makeAndUpload(date: date, api: api, calendar: calendar) {
            case .done:
                state.pendingDates.removeAll { $0 == date }
                save()
            case .later:
                save()
                return
            }
        }
    }

    private enum Outcome {
        case done
        case later
    }

    private func makeAndUpload(date: String, api: DogMonitorAPI, calendar: Calendar) async -> Outcome {
        let candidates = state.library.clipsRecorded(on: date, calendar: calendar)
            .filter { FileManager.default.fileExists(atPath: clipURL($0.eventID).path) }
        let planner = HighlightReelPlanner()
        guard let segments = planner.plan(candidates) else { return .done } // a quiet day: no reel

        // Ask first: a free household gets 403, and then there is no video to make.
        let target: PresignedUploadDTO
        do {
            target = try await api.requestReelUpload(date: date)
        } catch let error as APIError {
            switch error.code {
            case "premium_required", "storage_not_configured": return .done
            default: return .later
            }
        } catch {
            return .later
        }

        let output = directory.appendingPathComponent("reel-\(date).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        do {
            let clips = segments.map { ReelComposer.Piece(url: clipURL($0.eventID), start: $0.start, duration: $0.duration) }
            try await ReelComposer.export(clips, endCard: planner.configuration.endCard, to: output)
            try await api.upload(Data(contentsOf: output), to: target)
            try await api.attachReel(date: date)
            logger.info("Uploaded the highlight reel of \(date, privacy: .public)")
            return .done
        } catch {
            logger.error("Highlight reel failed: \(error.localizedDescription, privacy: .public)")
            return .later
        }
    }

    private func clipURL(_ eventID: UUID) -> URL {
        directory.appendingPathComponent("clips", isDirectory: true).appendingPathComponent("\(eventID.uuidString).mp4")
    }

    private func removeClips(_ ids: [UUID]) {
        for id in ids {
            try? FileManager.default.removeItem(at: clipURL(id))
        }
    }

    private func save() {
        // Days older than the clip library can't get a reel any more.
        let keep = Set(state.library.clips.map { DailySummaryAccumulator.dateKey($0.startedAt, calendar: .current) })
        state.pendingDates.removeAll { !keep.contains($0) }
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
    }
}

/// Stitches clip pieces into a 1080×1920 video (aspect-fill) and adds the end card.
enum ReelComposer {
    struct Piece: Sendable {
        var url: URL
        var start: TimeInterval
        var duration: TimeInterval
    }

    enum ComposeError: Error {
        case noVideo
        case exportFailed(String)
    }

    static let renderSize = CGSize(width: 1080, height: 1920)
    private static let timescale: CMTimeScale = 600

    static func export(_ pieces: [Piece], endCard: TimeInterval, to output: URL) async throws {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ComposeError.noVideo
        }
        let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)

        var cursor = CMTime.zero
        var last: (track: AVAssetTrack, start: CMTime)?
        for piece in pieces {
            let asset = AVURLAsset(url: piece.url)
            guard let source = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let range = CMTimeRange(
                start: CMTime(seconds: piece.start, preferredTimescale: timescale),
                duration: CMTime(seconds: piece.duration, preferredTimescale: timescale)
            )
            try video.insertTimeRange(range, of: source, at: cursor)
            if let audio, let sound = try await asset.loadTracks(withMediaType: .audio).first {
                try? audio.insertTimeRange(range, of: sound, at: cursor)
            }
            let (transform, size) = try await source.load(.preferredTransform, .naturalSize)
            layer.setTransform(fill(transform: transform, naturalSize: size), at: cursor)
            last = (source, range.start)
            cursor = cursor + range.duration
        }
        guard let last, cursor > .zero else { throw ComposeError.noVideo }

        // End card: a short stretch of the last clip, hidden, so the card sits on black.
        let footageEnd = cursor
        let filler = CMTime(seconds: 0.5, preferredTimescale: timescale)
        try video.insertTimeRange(CMTimeRange(start: last.start, duration: filler), of: last.track, at: footageEnd)
        let cardDuration = CMTime(seconds: endCard, preferredTimescale: timescale)
        video.scaleTimeRange(CMTimeRange(start: footageEnd, duration: filler), toDuration: cardDuration)
        layer.setOpacity(0, at: footageEnd)
        let total = footageEnd + cardDuration

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: total)
        instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
        instruction.layerInstructions = [layer]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]
        videoComposition.animationTool = endCardTool(showingAt: footageEnd.seconds)

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVC1920x1080) else {
            throw ComposeError.exportFailed("no export session")
        }
        session.videoComposition = videoComposition
        session.timeRange = CMTimeRange(start: .zero, duration: total)
        try? FileManager.default.removeItem(at: output)
        if #available(iOS 18, *) {
            try await session.export(to: output, as: .mp4)
        } else {
            session.outputURL = output
            session.outputFileType = .mp4
            await session.export()
            if session.status != .completed {
                throw ComposeError.exportFailed(session.error?.localizedDescription ?? "status \(session.status.rawValue)")
            }
        }
    }

    /// Scales the oriented frame to cover the vertical canvas, centered.
    private static func fill(transform: CGAffineTransform, naturalSize: CGSize) -> CGAffineTransform {
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(transform)
        guard oriented.width > 0, oriented.height > 0 else { return transform }
        let scale = max(renderSize.width / oriented.width, renderSize.height / oriented.height)
        let x = (renderSize.width - oriented.width * scale) / 2
        let y = (renderSize.height - oriented.height * scale) / 2
        return transform
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: x, y: y))
    }

    /// "Dog Monitor" fading in over black for the last seconds (free word of mouth when shared).
    private static func endCardTool(showingAt seconds: Double) -> AVVideoCompositionCoreAnimationTool {
        let frame = CGRect(origin: .zero, size: renderSize)
        let parent = CALayer()
        parent.frame = frame
        let videoLayer = CALayer()
        videoLayer.frame = frame
        parent.addSublayer(videoLayer)

        let title = CATextLayer()
        title.string = "Dog Monitor"
        title.font = CTFontCreateUIFontForLanguage(.emphasizedSystem, 84, nil)
        title.fontSize = 84
        title.foregroundColor = CGColor(gray: 1, alpha: 1)
        title.alignmentMode = .center
        title.contentsScale = 2
        title.frame = CGRect(x: 0, y: (renderSize.height - 110) / 2, width: renderSize.width, height: 110)
        title.opacity = 0

        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.beginTime = AVCoreAnimationBeginTimeAtZero + seconds
        fadeIn.duration = 0.4
        fadeIn.fillMode = .forwards
        fadeIn.isRemovedOnCompletion = false
        title.add(fadeIn, forKey: "fadeIn")
        parent.addSublayer(title)

        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
    }
}
