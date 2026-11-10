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
