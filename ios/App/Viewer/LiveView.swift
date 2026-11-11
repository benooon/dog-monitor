import DogMonitorCore
import SwiftUI

/// Full-screen live view of one camera: video edge to edge, a "Live" pill, and a floating
/// glass control bar (sound, talk, Lock Screen).
struct LiveView: View {
    let camera: DeviceDTO
    let dogName: String?
    let realtime: ViewerRealtime
    @State private var model: LiveViewModel
    @State private var showsLiveKeyScan = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let liveActivities = CameraLiveActivityController.shared

    init(camera: DeviceDTO, api: DogMonitorAPI, realtime: ViewerRealtime, dogName: String? = nil) {
        self.camera = camera
        self.dogName = dogName
        self.realtime = realtime
        _model = State(initialValue: LiveViewModel(cameraId: camera.id, api: api, realtime: realtime))
    }

    /// With a given model (previews and screenshots of each state).
    init(camera: DeviceDTO, model: LiveViewModel, realtime: ViewerRealtime, dogName: String? = nil) {
        self.camera = camera
        self.dogName = dogName
        self.realtime = realtime
        _model = State(initialValue: model)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let track = model.videoTrack {
                LiveVideoView(track: track)
                    .ignoresSafeArea()
            }
            VStack(spacing: DS.Spacing.l) {
                HStack {
                    if model.phase == .live {
                        StatusPill(title: "Live", tint: .red)
                            .transition(.opacity)
                    }
                    Spacer()
                }
                Spacer()
                status
                Spacer()
                if model.phase == .live {
                    controls
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(DS.Spacing.l)
            .animation(DS.Motion.animation(DS.Motion.gentle, reduceMotion: reduceMotion), value: model.phase)
            // Video is always dark, so the overlay uses dark semantic colors in either appearance.
            .environment(\.colorScheme, .dark)
        }
        .navigationTitle(Text(verbatim: camera.name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .sheet(isPresented: $showsLiveKeyScan) {
            LiveKeyScanView { key in
                model.useLiveKey(key)
            }
        }
    }

    /// Floating controls: camera sound, push-to-talk, and the Lock Screen Live Activity.
    private var controls: some View {
        VStack(spacing: DS.Spacing.s) {
            if model.isMicrophoneDenied {
                Text("Allow microphone access in Settings to talk to your dog.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: DS.Spacing.m) {
                if model.hasAudio {
                    soundButton
                }
                talkButton
                if liveActivities.isAvailable {
                    lockScreenButton
                }
            }
            .controlSize(.large)
        }
    }

    private var soundButton: some View {
        Button {
            model.toggleAudio()
        } label: {
            if model.isAudioMuted {
                Label("Unmute", systemImage: "speaker.slash.fill")
            } else {
                Label("Mute", systemImage: "speaker.wave.2.fill")
            }
        }
        .labelStyle(.iconOnly)
        .contentTransition(.symbolEffect(.replace))
        .liveControlStyle(isProminent: false)
    }

    /// Push-to-talk: tap to talk through the camera's speaker, tap again to stop.
    private var talkButton: some View {
        Button {
            model.toggleTalk()
        } label: {
            Label(
                model.isTalking ? LocalizedStringKey("Stop talking") : LocalizedStringKey("Talk"),
                systemImage: model.isTalking ? "mic.fill" : "mic"
            )
            .symbolEffect(.pulse, options: .repeating, isActive: model.isTalking && !reduceMotion)
            .frame(maxWidth: .infinity)
        }
        .liveControlStyle(isProminent: model.isTalking)
        .tint(model.isTalking ? .red : nil)
        .sensoryFeedback(.impact, trigger: model.isTalking)
        .accessibilityHint(Text("Your voice plays from the camera."))
        .accessibilityIdentifier("push-to-talk")
    }

    @ViewBuilder
    private var lockScreenButton: some View {
        if liveActivities.isShowing(camera.id) {
            Button("Hide from Lock Screen", systemImage: "lock.slash") {
                Task { await liveActivities.stop(cameraId: camera.id) }
            }
            .labelStyle(.iconOnly)
            .liveControlStyle(isProminent: false)
        } else {
            Button("Show on Lock Screen", systemImage: "lock.iphone") {
                let content = CameraLiveActivityContent(
                    state: realtime.dogStates[camera.id] ?? camera.currentDogState,
                    online: realtime.presence[camera.id] ?? camera.isOnline(now: .now)
                )
                try? liveActivities.start(camera: camera, dogName: dogName, content: content)
            }
            .labelStyle(.iconOnly)
            .liveControlStyle(isProminent: false)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .connecting:
            progress("Connecting…")
        case .waitingForCamera:
            progress("Waiting for the camera…")
        case .reconnecting:
            progress("Connection lost. Reconnecting…")
        case .live:
            EmptyView()
        case .viewerLimitReached:
            ContentUnavailableView {
                Label("This camera already has 5 viewers.", systemImage: "person.3.fill")
            } description: {
                Text("Try again when someone stops watching.")
            } actions: {
                Button("Try again") { model.retry() }
                    .buttonStyle(.bordered)
            }
        case .notConfigured:
            ContentUnavailableView("Live view isn't set up on the server yet.", systemImage: "video.slash")
        case .needsLiveKey:
            ContentUnavailableView {
                Label("Scan the invite code to watch live.", systemImage: "lock.fill")
            } description: {
                Text("Your household's video is private. Scan the invite code on the owner's phone once, and this phone can watch.")
            } actions: {
                Button("Scan invite code") { showsLiveKeyScan = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("live-scan-key")
            }
        case .wrongLiveKey:
            ContentUnavailableView {
                Label("Scan the invite code again to watch live.", systemImage: "lock.fill")
            } description: {
                Text("The key on this phone no longer opens your household's video. Scan the invite code on the owner's phone, and this phone can watch again.")
            } actions: {
                Button("Scan invite code") { showsLiveKeyScan = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("live-rescan-key")
            }
        case .cameraNeedsKey:
            ContentUnavailableView {
                Label("Live view is off on this camera.", systemImage: "video.slash")
            } description: {
                Text("On the camera, scan the invite code on the owner's phone once. Then try again.")
            } actions: {
                Button("Try again") { model.retry() }
                    .buttonStyle(.bordered)
            }
        case .notPrivate:
            ContentUnavailableView {
                Label("This video isn't private, so it isn't shown.", systemImage: "exclamationmark.shield")
            } description: {
                Text("On the camera, stop it and scan a new invite code from the owner's phone. Then try again.")
            } actions: {
                Button("Try again") { model.retry() }
                    .buttonStyle(.bordered)
            }
        case .failed:
            ContentUnavailableView {
                Label("Couldn't open live view.", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try again") { model.retry() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func progress(_ title: LocalizedStringKey) -> some View {
        ProgressView(title)
            .padding(.horizontal, DS.Spacing.l)
            .padding(.vertical, DS.Spacing.m)
            .glassSurface(in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
    }
}

private extension View {
    /// Glass buttons on iOS 26 and later (prominent while active), bordered before.
    @ViewBuilder
    func liveControlStyle(isProminent: Bool) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            if isProminent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            legacyLiveControlStyle(isProminent: isProminent)
        }
        #else
        legacyLiveControlStyle(isProminent: isProminent)
        #endif
    }

    @ViewBuilder
    func legacyLiveControlStyle(isProminent: Bool) -> some View {
        if isProminent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

// Previews have no server, so they show the "couldn't open" state over black.
#Preview {
    let api = DogMonitorAPI(baseURL: URL(string: "https://example.invalid")!)
    NavigationStack {
        LiveView(camera: .previewCamera, api: api, realtime: ViewerRealtime(api: api), dogName: "Rex")
    }
}

#Preview("Hebrew (RTL)") {
    let api = DogMonitorAPI(baseURL: URL(string: "https://example.invalid")!)
    NavigationStack {
        LiveView(camera: .previewCamera, api: api, realtime: ViewerRealtime(api: api), dogName: "רקס")
    }
    .environment(\.locale, Locale(identifier: "he"))
    .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    let api = DogMonitorAPI(baseURL: URL(string: "https://example.invalid")!)
    NavigationStack {
        LiveView(camera: .previewCamera, api: api, realtime: ViewerRealtime(api: api), dogName: "Rex")
    }
    .preferredColorScheme(.dark)
}
