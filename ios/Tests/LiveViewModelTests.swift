import DogMonitorCore
import XCTest
@testable import DogMonitor

@MainActor
final class LiveViewModelTests: XCTestCase {
    private let api = DogMonitorAPI(baseURL: URL(string: "http://localhost:1")!, credential: .user(token: "jwt"))

    func testStartsConnectingWithoutVideo() {
        let model = LiveViewModel(cameraId: UUID(), api: api, realtime: ViewerRealtime(api: api))
        XCTAssertEqual(model.phase, .connecting)
        XCTAssertNil(model.videoTrack)
        model.stop() // safe before start
    }

    func testAudioMuteIsRememberedAcrossSessions() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LiveViewModelTests-\(UUID().uuidString)"))
        let first = LiveViewModel(cameraId: UUID(), api: api, realtime: ViewerRealtime(api: api), defaults: defaults)
        XCTAssertFalse(first.isAudioMuted)
        XCTAssertFalse(first.hasAudio)
        first.toggleAudio()
        XCTAssertTrue(first.isAudioMuted)

        let second = LiveViewModel(cameraId: UUID(), api: api, realtime: ViewerRealtime(api: api), defaults: defaults)
        XCTAssertTrue(second.isAudioMuted)
        second.toggleAudio()
        XCTAssertFalse(defaults.bool(forKey: LiveViewModel.audioMutedKey))
    }

    func testTalkingIsOffAndIgnoredUntilLive() {
        let model = LiveViewModel(cameraId: UUID(), api: api, realtime: ViewerRealtime(api: api))
        XCTAssertFalse(model.isTalking)
        model.toggleTalk() // no room yet: nothing happens, no permission prompt
        XCTAssertFalse(model.isTalking)
        XCTAssertFalse(model.isMicrophoneDenied)
    }

    func testTalkbackPlayerIsQuietUntilAudioArrives() {
        let player = TalkbackPlayer()
        XCTAssertFalse(player.isViewerTalking)
        player.stop()
        XCTAssertFalse(player.isViewerTalking)
    }

    func testRealtimeStartsDisconnectedWithNoPresence() {
        let realtime = ViewerRealtime(api: api)
        XCTAssertFalse(realtime.isConnected)
        XCTAssertTrue(realtime.presence.isEmpty)
        realtime.unwatch(UUID()) // no-op when not watching
    }
}
