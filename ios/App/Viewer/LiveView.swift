import DogMonitorCore
import SwiftUI

/// Full-screen live view of one camera.
struct LiveView: View {
    let cameraName: String
    @State private var model: LiveViewModel

    init(camera: DeviceDTO, api: DogMonitorAPI, realtime: ViewerRealtime) {
        cameraName = camera.name
        _model = State(initialValue: LiveViewModel(cameraId: camera.id, api: api, realtime: realtime))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let track = model.videoTrack {
                LiveVideoView(track: track)
                    .ignoresSafeArea()
            }
            VStack {
                HStack {
                    if model.phase == .live {
                        Label("Live", systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.red, in: Capsule())
                    }
                    Spacer()
                }
                Spacer()
                status
                Spacer()
                if model.phase == .live {
                    talkControl
                }
            }
            .padding()
            .foregroundStyle(.white)
        }
        .navigationTitle(Text(verbatim: cameraName))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if model.hasAudio {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.toggleAudio()
                    } label: {
                        if model.isAudioMuted {
                            Label("Unmute", systemImage: "speaker.slash.fill")
                        } else {
                            Label("Mute", systemImage: "speaker.wave.2.fill")
                        }
                    }
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    /// Push-to-talk: tap to talk through the camera's speaker, tap again to stop.
    private var talkControl: some View {
        VStack(spacing: 8) {
            if model.isMicrophoneDenied {
                Text("Allow microphone access in Settings to talk to your dog.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }
            Button {
                model.toggleTalk()
            } label: {
                Label(
                    model.isTalking ? LocalizedStringKey("Stop talking") : LocalizedStringKey("Talk"),
                    systemImage: model.isTalking ? "mic.fill" : "mic"
                )
                .font(.headline)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .frame(minHeight: 44)
                .background(model.isTalking ? AnyShapeStyle(.red) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
                .symbolEffect(.pulse, options: .repeating, isActive: model.isTalking)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact, trigger: model.isTalking)
            .accessibilityHint(Text("Your voice plays from the camera."))
            .accessibilityIdentifier("push-to-talk")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .connecting:
            ProgressView("Connecting…").tint(.white)
        case .waitingForCamera:
            ProgressView("Waiting for the camera…").tint(.white)
        case .reconnecting:
            ProgressView("Connection lost. Reconnecting…").tint(.white)
        case .live:
            EmptyView()
        case .viewerLimitReached:
            Text("This camera already has 5 viewers.")
        case .notConfigured:
            Text("Live view isn't set up on the server yet.")
        case .failed:
            VStack(spacing: 12) {
                Text("Couldn't open live view.")
                Button("Try again") { model.retry() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
