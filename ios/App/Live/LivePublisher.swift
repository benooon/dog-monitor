import DogMonitorCore
import Foundation
@preconcurrency import LiveKit

/// Publishes the capture session's video to the camera's LiveKit room.
///
/// Frames come from our single `AVCaptureSession` (via `BufferCapturer`), so LiveKit never opens
/// the camera itself. Simulcast is on by default, which gives viewers 720p and lower layers.
/// Audio is not published yet (see BACKLOG: sharing the mic between capture and WebRTC).
actor LivePublisher {
    enum PublishError: Error {
        case noBufferCapturer
    }

    private var room: Room?
    private var feed: Task<Void, Never>?

    var isConnected: Bool {
        room?.connectionState == .connected
    }

    func start(token: LiveTokenDTO, frames: AsyncStream<CaptureSample>) async throws {
        await stop()
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
    }

    func stop() async {
        let room = self.room
        let feed = self.feed
        self.room = nil
        self.feed = nil
        feed?.cancel()
        await room?.disconnect()
    }
}
