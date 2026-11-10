import DogMonitorCore
import Foundation
@preconcurrency import LiveKit
import os

/// Publishes the capture session's video and audio to the camera's LiveKit room.
///
/// Frames come from our single `AVCaptureSession` (via `BufferCapturer`), so LiveKit never opens
/// the camera itself. Simulcast is on by default, which gives viewers 720p and lower layers.
///
/// Audio works the same way: the capture session owns the microphone (bark detection needs it
/// all the time), so LiveKit's audio engine runs in manual rendering mode, never opens the mic,
/// and gets our captured buffers through `AudioManager.shared.mixer.capture(appAudio:)`.
/// Manual rendering also means remote audio is not played automatically, so viewers' push-to-talk
/// audio goes through `TalkbackPlayer`.
actor LivePublisher {
    enum PublishError: Error {
        case noBufferCapturer
    }

    private var room: Room?
    private var feed: Task<Void, Never>?
    private var audioFeed: Task<Void, Never>?
    private var talkbackWatch: Task<Void, Never>?
    private var talkbackTracks: Set<ObjectIdentifier> = []
    private let talkback = TalkbackPlayer()
    private let logger = Logger(subsystem: "com.benooon.dogmonitor", category: "LivePublisher")

    var isConnected: Bool {
        room?.connectionState == .connected
    }

    /// - Parameter audio: captured audio samples; publishing audio is best effort, so a failure
    ///   there leaves the video stream running.
    func start(token: LiveTokenDTO, frames: AsyncStream<CaptureSample>, audio: AsyncStream<CaptureSample>) async throws {
        await stop()
        Self.useCapturedAudio()
        let room = Room()
        try await room.connect(url: token.url, token: token.token)
        let track = await LocalVideoTrack.createBufferTrack(name: "camera", source: .camera)
        guard let capturer = track.capturer as? BufferCapturer else {
            await room.disconnect()
            throw PublishError.noBufferCapturer
        }
        do {
            _ = try await room.localParticipant.publish(videoTrack: track)
        } catch {
            await room.disconnect()
            throw error
        }
        self.room = room
        feed = Task.detached(priority: .userInitiated) {
            for await sample in frames where sample.kind == .video {
                capturer.capture(sample.buffer)
            }
        }
        await startAudio(in: room, samples: audio)
        watchTalkback(in: room)
    }

    /// Whether a viewer's voice played in the last moment (shown on the camera screen).
    nonisolated var isViewerTalking: Bool {
        talkback.isViewerTalking
    }

    func stop() async {
        let room = self.room
        let feed = self.feed
        let audioFeed = self.audioFeed
        self.room = nil
        self.feed = nil
        self.audioFeed = nil
        feed?.cancel()
        audioFeed?.cancel()
        talkbackWatch?.cancel()
        talkbackWatch = nil
        talkbackTracks.removeAll()
        talkback.stop()
        await room?.disconnect()
    }

    // MARK: - Push-to-talk

    /// Viewers publish a microphone track while they talk; play each one as it appears.
    private func watchTalkback(in room: Room) {
        talkbackWatch?.cancel()
        talkbackWatch = Task { [weak self] in
            while !Task.isCancelled {
                await self?.attachViewerAudio(in: room)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func attachViewerAudio(in room: Room) {
        for participant in room.remoteParticipants.values {
            for publication in participant.audioTracks {
                guard let track = publication.track as? RemoteAudioTrack else { continue }
                if talkbackTracks.insert(ObjectIdentifier(track)).inserted {
                    track.add(audioRenderer: talkback)
                }
            }
        }
    }

    // MARK: - Audio

    /// Switches LiveKit's audio engine to manual rendering once, before any room connects.
    private static func useCapturedAudio() {
        guard !AudioManager.shared.isManualRenderingMode else { return }
        do {
            try AudioManager.shared.setManualRenderingMode(true)
        } catch {
            Logger(subsystem: "com.benooon.dogmonitor", category: "LivePublisher")
                .error("Could not enable manual audio rendering: \(String(describing: error), privacy: .public)")
        }
    }

    private func startAudio(in room: Room, samples: AsyncStream<CaptureSample>) async {
        guard AudioManager.shared.isManualRenderingMode else {
            // Without manual rendering LiveKit would open the mic itself and fight the capture session.
            logger.warning("Not publishing audio: manual rendering is off")
            return
        }
        do {
            _ = try await room.localParticipant.setMicrophone(enabled: true)
        } catch {
            logger.error("Could not publish audio: \(String(describing: error), privacy: .public)")
            return
        }
        audioFeed = Task.detached(priority: .userInitiated) {
            for await sample in samples where sample.kind == .audio {
                if let buffer = AudioSampleBuffer.pcmBuffer(from: sample.buffer) {
                    AudioManager.shared.mixer.capture(appAudio: buffer)
                }
            }
        }
    }
}
