import DogMonitorCore
import SwiftUI
import UIKit

/// Camera mode (SPEC §8): a start screen, then a black, dimmed screen while capturing.
/// A tap shows the live preview and the stop button.
struct CameraModeView: View {
    @State private var model = CameraModeModel()
    @Environment(\.scenePhase) private var scenePhase
    let onChangeRole: () -> Void

    init(onChangeRole: @escaping () -> Void) {
        self.onChangeRole = onChangeRole
    }

    var body: some View {
        Group {
            switch model.status {
            case .idle:
                startScreen
            case .starting:
                ProgressView("Starting camera…")
            case .running:
                runningScreen
            case .denied:
                messageScreen(
                    "Camera access is off. Allow it in Settings to use this phone as a camera.",
                    actionTitle: "Open Settings"
                ) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            case .failed:
                messageScreen("Couldn't start the camera.", actionTitle: "Try again") {
                    Task { await model.start() }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(isActive: phase == .active)
        }
        .onDisappear { model.stop() }
    }

    private var startScreen: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "video.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Keep this phone plugged in and the app open.")
                .font(.headline)
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                Task { await model.start() }
            } label: {
                Text("Start camera")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("start-camera")
            Button("Change role", action: onChangeRole)
        }
        .padding()
    }

    private var runningScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.isPreviewVisible {
                CameraPreview(session: model.capture.session)
                    .ignoresSafeArea()
            }
            VStack(spacing: 12) {
                statusIndicator
                if !model.isPreviewVisible {
                    Text("Tap the screen to show the preview.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.4))
                }
                if model.isPreviewVisible, model.hasAudio {
                    detectionOverlay
                }
                Spacer()
                if model.isPreviewVisible {
                    Button(role: .destructive) {
                        model.stop()
                    } label: {
                        Text("Stop camera")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("stop-camera")
                }
            }
            .padding()
        }
        .contentShape(Rectangle())
        .onTapGesture { model.tap() }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
    }

    private var statusIndicator: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            Text("Camera on")
            if model.isPreviewVisible, model.videoFPS > 0 {
                Text(verbatim: "· \(Int(model.videoFPS.rounded())) fps")
                    .monospacedDigit()
            }
            if !model.hasAudio {
                Image(systemName: "mic.slash.fill")
                    .accessibilityLabel(Text("Microphone off — barking can't be detected."))
            }
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.6))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(0.08), in: Capsule())
    }

    /// Debug overlay: what the audio analyzer heard recently.
    private var detectionOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Barks in the last minute: \(model.recentBarkCount)")
                .font(.caption.bold())
            ForEach(Array(model.detectionLog.latest(4).enumerated()), id: \.offset) { _, detection in
                HStack {
                    Text(verbatim: detection.kind.rawValue)
                    Spacer()
                    Text(verbatim: "\(Int((detection.confidence * 100).rounded()))%")
                        .monospacedDigit()
                    Text(detection.timestamp, style: .relative)
                        .monospacedDigit()
                }
                .font(.caption2)
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(maxWidth: 260)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func messageScreen(
        _ message: LocalizedStringKey,
        actionTitle: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Text(message)
                .multilineTextAlignment(.center)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
            Spacer()
            Button("Change role", action: onChangeRole)
        }
        .padding()
    }
}

#Preview {
    CameraModeView {}
}

#Preview("Hebrew (RTL)") {
    CameraModeView {}
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}
