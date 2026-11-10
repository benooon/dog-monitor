import DogMonitorCore
import Foundation
@preconcurrency import LiveKit

/// Publishes the capture session's video to the camera's LiveKit room.
///
/// Frames come from our single `AVCaptureSession` (via `BufferCapturer`), so LiveKit never opens
/// the camera itself. Simulcast is on by default, which gives viewers 720p and lower layers.
/// Audio is not published yet (see BACKLOG: sharing the mic between capture and WebRTC).
final class LivePublisher: @unchecked Sendable {
    enum PublishError: Error {
        case noBufferCapturer
    }

    private let lock = NSLock()
    private var room: Room?
    private var feed: Task<Void, Never>?

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return room?.connectionState == .connected
    }

    func start(token: LiveTokenDTO, frames: AsyncStream<CaptureSample>) async throws {
        await stop()
        let room = Room()
        try await room.connect(url: token.url, token: token.token)
        let track = LocalVideoTrack.createBufferTrack(name: "camera", source: .camera)
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
        let feed = Task.detached(priority: .userInitiated) {
            for await sample in frames where sample.kind == .video {
                capturer.capture(sample.buffer)
            }
        }
        lock.lock()
        self.room = room
        self.feed = feed
        lock.unlock()
    }

    func stop() async {
        lock.lock()
        let room = self.room
        let feed = self.feed
        self.room = nil
        self.feed = nil
        lock.unlock()
        feed?.cancel()
        await room?.disconnect()
    }
}
