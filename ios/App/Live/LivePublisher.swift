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
/// Manual rendering also means remote audio is not played automatically (matters for push-to-talk).
actor LivePublisher {
    enum PublishError: Error {
        case noBufferCapturer
    }

    private var room: Room?
    private var feed: Task<Void, Never>?
    private var audioFeed: Task<Void, Never>?
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
        await room?.disconnect()
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
