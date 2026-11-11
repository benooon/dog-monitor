import DogMonitorCore
import Foundation
@preconcurrency import LiveKit
import os

/// Collects LiveKit's frame encryption state for the camera's tracks, so a viewer with the
/// wrong key sees "Scan the invite code" instead of black video. LiveKit calls the delegate on
/// its own queues; the state sits behind a lock and the view model polls it.
///
/// Rooms hold delegates weakly: keep a strong reference while the room is in use.
final class LiveE2EEObserver: NSObject, RoomDelegate, Sendable {
    private let watch = OSAllocatedUnfairLock(initialState: LiveDecryptionWatch())

    nonisolated func room(_ room: Room, trackPublication: TrackPublication, didUpdateE2EEState state: E2EEState) {
        // Our own microphone is encryption-side; only the camera's tracks say whether our key opens them.
        guard trackPublication is RemoteTrackPublication else { return }
        let frame = Self.frameState(state)
        let now = Date.now
        watch.withLock { $0.record(frame, at: now) }
    }

    nonisolated func isWrongKey(at time: Date = .now) -> Bool {
        watch.withLock { $0.isWrongKey(at: time) }
    }

    nonisolated static func frameState(_ state: E2EEState) -> LiveDecryptionWatch.FrameState {
        switch state {
        case .ok: .ok
        case .missing_key, .decryption_failed: .failing
        default: .neutral
        }
    }
}
