import AVFoundation
import DogMonitorCore
import Foundation
@preconcurrency import LiveKit
import Observation
import os

/// One live view session: announce the watch, get a viewer token, join the camera's room and
/// wait for its video. Reconnects with backoff when the room drops.
@MainActor
@Observable
final class LiveViewModel {
    enum Phase: Equatable {
        case connecting
        /// In the room; the camera starts publishing once it hears we're watching.
        case waitingForCamera
        case live
        case reconnecting
        case viewerLimitReached
        case notConfigured
        case failed
        /// The household's video is end-to-end encrypted and this phone has no key yet.
        case needsLiveKey
        /// The camera sent clear video where it should be encrypted, so it isn't shown.
        case notPrivate
    }

    /// Ends a session for good (no reconnect) with an encryption problem.
    private enum EncryptionStop: Error {
        case needsKey
        case notPrivate
    }

    static let cameraWaitTimeout: Duration = .seconds(30)
    static let audioMutedKey = "liveView.audioMuted"

    private(set) var phase: Phase = .connecting
    private(set) var videoTrack: VideoTrack?
    /// Whether the camera publishes audio (shows the mute button).
    private(set) var hasAudio = false
    /// The viewer's choice, remembered across sessions. Muting also stops the server from
    /// sending the audio. Sound plays through the speaker even with the silent switch on
    /// (LiveKit's `.playback` session), since opening live view is an explicit request.
    private(set) var isAudioMuted: Bool
    /// Push-to-talk: the viewer's mic is published to the camera's speaker.
    private(set) var isTalking = false
    /// Microphone permission was refused, so talking is not possible.
    private(set) var isMicrophoneDenied = false

    let cameraId: UUID
    private let api: DogMonitorAPI
    private let realtime: ViewerRealtime
    private let logger = Logger(subsystem: "com.benooon.dogmonitor", category: "LiveView")
    @ObservationIgnored private var room: Room?
    @ObservationIgnored private var session: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let liveKeys: LiveKeyStore

    init(
        cameraId: UUID,
        api: DogMonitorAPI,
        realtime: ViewerRealtime,
        defaults: UserDefaults = .standard,
        liveKeys: LiveKeyStore = LiveKeyStore(store: KeychainStore())
    ) {
        self.cameraId = cameraId
        self.api = api
        self.realtime = realtime
        self.defaults = defaults
        self.liveKeys = liveKeys
        isAudioMuted = defaults.bool(forKey: Self.audioMutedKey)
    }

    func toggleAudio() {
        isAudioMuted.toggle()
        defaults.set(isAudioMuted, forKey: Self.audioMutedKey)
        if let room {
            Task { await applyAudioPreference(in: room) }
        }
    }

    /// Starts or stops talking through the camera. While talking, the camera's own audio is
    /// paused so the viewer doesn't hear themselves echo back.
    func toggleTalk() {
        guard let room, phase == .live else { return }
        let talk = !isTalking
        Task {
            if talk {
                guard await AVAudioApplication.requestRecordPermission() else {
                    isMicrophoneDenied = true
                    return
                }
                isMicrophoneDenied = false
                Self.useDeviceMicrophone()
            }
            do {
                try await room.localParticipant.setMicrophone(enabled: talk)
                isTalking = talk
            } catch {
                logger.info("Could not change talking: \(String(describing: error), privacy: .public)")
                isTalking = false
            }
            await applyAudioPreference(in: room)
        }
    }

    /// A phone that was a camera earlier in this launch left LiveKit in manual rendering mode,
    /// which never opens the mic; viewers need the normal mode.
    private static func useDeviceMicrophone() {
        guard AudioManager.shared.isManualRenderingMode else { return }
        try? AudioManager.shared.setManualRenderingMode(false)
    }

    func start() {
        guard session == nil else { return }
        realtime.watch(cameraId)
        session = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        session?.cancel()
        session = nil
        realtime.unwatch(cameraId)
        videoTrack = nil
        hasAudio = false
        isTalking = false
        let room = room
        self.room = nil
        Task { await room?.disconnect() }
    }

    /// A key scanned from the owner's invite QR code: keep it and try again.
    func useLiveKey(_ key: LiveKey) {
        do {
            try liveKeys.save(key)
        } catch {
            logger.error("Could not save the live key: \(String(describing: error), privacy: .public)")
            return
        }
        retry()
    }

    /// Restarts after a terminal failure (button on the error screen).
    func retry() {
        stop()
        phase = .connecting
        start()
    }

    // MARK: - Private

    private func run() async {
        var backoff = ReconnectBackoff(initial: 2, maximum: 30)
        while !Task.isCancelled {
            do {
                try await connectAndWatch()
                backoff.reset()
            } catch let error as APIError {
                switch error {
                case .http(status: 409, code: "viewer_limit_reached"?):
                    phase = .viewerLimitReached
                    return
                case .http(status: 503, _):
                    phase = .notConfigured
                    return
                case .http(status: 404, _), .http(status: 401, _), .http(status: 403, _), .http(status: 409, _):
                    phase = .failed
                    return
                default:
                    logger.info("Live view error: \(String(describing: error), privacy: .public)")
                }
            } catch is CancellationError {
                return
            } catch let stop as EncryptionStop {
                videoTrack = nil
                phase = stop == .needsKey ? .needsLiveKey : .notPrivate
                await disconnectRoom()
                return
            } catch {
                logger.info("Live view error: \(String(describing: error), privacy: .public)")
            }
            guard !Task.isCancelled else { return }
            videoTrack = nil
            isTalking = false
            phase = .reconnecting
            try? await Task.sleep(for: .seconds(backoff.nextDelay()))
        }
    }

    /// Returns when the room disconnects (to be retried), throws on failure.
    private func connectAndWatch() async throws {
        let token = try await api.liveToken(cameraId: cameraId)
        try Task.checkCancellation()
        let key = liveKeys.load()
        let householdEncrypted = token.isHouseholdEncrypted
        if case .needsKey = LiveEncryption.mode(key: key, householdEncrypted: householdEncrypted) {
            throw EncryptionStop.needsKey
        }
        let pins = EncryptedCameraPins(defaults: defaults)
        let room = Room(roomOptions: LiveRoomOptions.make(key: key))
        self.room = room
        try await room.connect(url: token.url, token: token.token)
        phase = .waitingForCamera

        var waited: Duration = .zero
        while !Task.isCancelled {
            guard room.connectionState != .disconnected else { break }
            if let video = Self.cameraVideo(in: room) {
                let (track, encrypted) = video
                switch LiveEncryption.decision(
                    trackEncrypted: encrypted,
                    hasKey: key != nil,
                    householdEncrypted: householdEncrypted,
                    cameraPinned: pins.isPinned(cameraId)
                ) {
                case .show:
                    if encrypted { pins.pin(cameraId) }
                case .needsKey:
                    throw EncryptionStop.needsKey
                case .refuse:
                    throw EncryptionStop.notPrivate
                }
                if videoTrack !== track {
                    videoTrack = track
                }
                phase = room.connectionState == .reconnecting ? .reconnecting : .live
                waited = .zero
            } else {
                videoTrack = nil
                if phase == .live { phase = .waitingForCamera }
                waited += .milliseconds(500)
                if waited >= Self.cameraWaitTimeout, phase == .waitingForCamera {
                    // Keep waiting, but re-announce in case the camera missed the join.
                    realtime.watch(cameraId)
                    waited = .zero
                }
            }
            await applyAudioPreference(in: room)
            try? await Task.sleep(for: .milliseconds(500))
        }
        await room.disconnect()
        if self.room === room { self.room = nil }
    }

    /// Enables or disables every remote audio track to match `isAudioMuted` (no-op when it
    /// already matches), and updates `hasAudio`.
    private func applyAudioPreference(in room: Room) async {
        let publications = room.remoteParticipants.values
            .flatMap(\.audioTracks)
            .compactMap { $0 as? RemoteTrackPublication }
        hasAudio = !publications.isEmpty
        let enabled = !isAudioMuted && !isTalking
        for publication in publications where publication.isEnabled != enabled {
            do {
                try await publication.set(enabled: enabled)
            } catch {
                logger.info("Could not change audio: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The camera's video track, and whether its frames are end-to-end encrypted.
    private static func cameraVideo(in room: Room) -> (VideoTrack, Bool)? {
        for participant in room.remoteParticipants.values {
            for publication in participant.videoTracks {
                if let track = publication.track as? VideoTrack {
                    return (track, publication.encryptionType != EncryptionType.none)
                }
            }
        }
        return nil
    }

    private func disconnectRoom() async {
        let room = room
        self.room = nil
        await room?.disconnect()
    }
}
