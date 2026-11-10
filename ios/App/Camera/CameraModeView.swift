import DogMonitorCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Camera mode (SPEC §8): a start screen, then a black, dimmed screen while capturing.
/// A tap shows the live preview with floating glass controls.
struct CameraModeView: View {
    @State private var model = CameraModeModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsPairing = false
    @State private var showsZones = false
    @State private var hasCustomModel = CustomSoundModel.isInstalled
    @State private var showsModelImporter = false
    @State private var modelFailed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
                    title: "Camera access is off",
                    message: "Allow it in Settings to use this phone as a camera.",
                    systemImage: "video.slash",
                    actionTitle: "Open Settings"
                ) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            case .failed:
                messageScreen(
                    title: "Couldn't start the camera",
                    message: "Close other apps that use the camera, then try again.",
                    systemImage: "exclamationmark.triangle",
                    actionTitle: "Try again"
                ) {
                    Task { await model.start() }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(isActive: phase == .active)
        }
        .onDisappear { model.stop() }
        .sheet(isPresented: $showsZones) {
            ZoneEditorView(model: model)
        }
        .sheet(isPresented: $showsPairing) {
            CameraPairingView { credential in
                model.didPair(with: credential)
            }
        }
    }

    // MARK: Start

    private var startScreen: some View {
        // Centered when it fits; scrolls at the largest text sizes.
        ViewThatFits(in: .vertical) {
            startHeader
                .frame(maxHeight: .infinity)
            ScrollView {
                startHeader
                    .padding(.vertical, DS.Spacing.section)
            }
        }
        .safeAreaInset(edge: .bottom) {
            startActions
        }
        .padding(.horizontal, DS.Spacing.xl)
        .padding(.bottom, DS.Spacing.l)
        .fileImporter(isPresented: $showsModelImporter, allowedContentTypes: Self.modelTypes) { result in
            guard case .success(let url) = result else { return }
            Task {
                do {
                    try await CustomSoundModel.install(from: url)
                    hasCustomModel = true
                } catch {
                    modelFailed = true
                }
            }
        }
        .alert("Couldn't use this model", isPresented: $modelFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Pick a sound classifier made with Create ML. See the training guide.")
        }
    }

    private var startHeader: some View {
        VStack(spacing: DS.Spacing.l) {
            Image(systemName: "video.fill")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Keep this phone plugged in and the app open.")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if !model.isPaired {
                Text("This phone isn't paired yet, so live view is off. Barking is still detected here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Pair this camera", systemImage: "qrcode") { showsPairing = true }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("pair-camera")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var startActions: some View {
        VStack(spacing: DS.Spacing.l) {
            PrimaryButton(title: "Start camera", systemImage: "video.fill") {
                Task { await model.start() }
            }
            .accessibilityIdentifier("start-camera")
            HStack(spacing: DS.Spacing.m) {
                soundModelMenu
                Spacer(minLength: DS.Spacing.s)
                Button("Change role", action: onChangeRole)
            }
            .font(.footnote)
        }
        .padding(.top, DS.Spacing.l)
    }

    private static var modelTypes: [UTType] {
        [UTType(filenameExtension: "mlmodel"), UTType(filenameExtension: "mlpackage")].compactMap { $0 }
    }

    /// Which sound model detects barking: the built-in one, or one trained on this household's clips.
    private var soundModelMenu: some View {
        Menu {
            Button("Load a trained model…", systemImage: "square.and.arrow.down") { showsModelImporter = true }
            if hasCustomModel {
                Button("Use the built-in model", systemImage: "arrow.counterclockwise") {
                    CustomSoundModel.remove()
                    hasCustomModel = false
                }
            }
        } label: {
            Label(hasCustomModel ? "Sound model: trained" : "Sound model: built-in", systemImage: "waveform.badge.magnifyingglass")
                .font(.footnote)
        }
        .accessibilityIdentifier("sound-model")
    }

    // MARK: Running

    private var runningScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.isPreviewVisible {
                CameraPreview(session: model.capture.session)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
            VStack(spacing: DS.Spacing.m) {
                statusIndicator
                ForEach(model.healthWarnings, id: \.self) { warning in
                    HealthWarningCard(warning: warning)
                }
                if !model.isPreviewVisible {
                    Text("Tap the screen to show the preview.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                if model.isPreviewVisible, model.hasAudio {
                    detectionOverlay
                        .transition(.opacity)
                }
                Spacer(minLength: DS.Spacing.l)
                if model.isPreviewVisible {
                    cameraControls
                        .transition(controlsTransition)
                }
            }
            .padding(DS.Spacing.l)
        }
        .animation(DS.Motion.animation(DS.Motion.gentle, reduceMotion: reduceMotion), value: model.isPreviewVisible)
        .contentShape(Rectangle())
        .onTapGesture { model.tap() }
        .accessibilityAction(named: Text("Show preview")) { model.tap() }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
    }

    private var controlsTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    /// Floating glass controls over the preview. Side by side, stacked at accessibility text sizes.
    private var cameraControls: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: DS.Spacing.m))
            : AnyLayout(HStackLayout(spacing: DS.Spacing.m))
        return GlassControlGroup {
            layout {
                Button {
                    showsZones = true
                } label: {
                    Label("Zones", systemImage: "square.dashed")
                        .frame(maxWidth: .infinity)
                }
                .cameraControlStyle(prominent: false)
                .accessibilityIdentifier("edit-zones")
                Button(role: .destructive) {
                    model.stop()
                } label: {
                    Label("Stop camera", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .cameraControlStyle(prominent: true)
                .tint(.red)
                .accessibilityIdentifier("stop-camera")
            }
            .controlSize(.large)
        }
    }

    private var statusIndicator: some View {
        HStack(spacing: DS.Spacing.s) {
            Image(systemName: "circle.fill")
                .imageScale(.small)
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text("Camera on")
            if let state = model.dogState.label {
                Text(verbatim: "·")
                    .accessibilityHidden(true)
                Text(state)
            }
            if model.isPreviewVisible, model.videoFPS > 0 {
                Text(verbatim: "· \(Int(model.videoFPS.rounded())) fps")
                    .monospacedDigit()
            }
            if let live = model.live {
                if live.viewerCount > 0 {
                    // Privacy (SPEC §10): always show when someone is watching.
                    Label {
                        Text("\(live.viewerCount) watching")
                            .contentTransition(.numericText(value: Double(live.viewerCount)))
                    } icon: {
                        Image(systemName: "eye.fill")
                    }
                    .foregroundStyle(.primary)
                } else if live.link == .offline {
                    Image(systemName: "wifi.slash")
                        .accessibilityLabel(Text("Offline"))
                }
            }
            if model.live?.isViewerTalking == true {
                // Privacy (SPEC §10): show when someone is talking through this phone.
                Label {
                    Text("Someone is talking")
                } icon: {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                }
                .foregroundStyle(.primary)
            }
            if !model.hasAudio {
                Image(systemName: "mic.slash.fill")
                    .accessibilityLabel(Text("Microphone off — barking can't be detected."))
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.s)
        .glassSurface()
        .accessibilityElement(children: .combine)
    }

    /// Debug overlay: what the audio analyzer heard recently.
    private var detectionOverlay: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Barks in the last minute: \(model.recentBarkCount)")
                    .font(.caption.bold())
                    .contentTransition(.numericText(value: Double(model.recentBarkCount)))
                ForEach(Array(model.detectionLog.latest(4).enumerated()), id: \.offset) { _, detection in
                    HStack(spacing: DS.Spacing.s) {
                        Text(verbatim: detection.kind.rawValue)
                        Spacer(minLength: DS.Spacing.s)
                        Text(verbatim: "\(Int((detection.confidence * 100).rounded()))%")
                            .monospacedDigit()
                        Text(detection.timestamp, style: .relative)
                            .monospacedDigit()
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: Self.detectionOverlayMaxWidth)
    }

    private static let detectionOverlayMaxWidth: CGFloat = 280

    // MARK: Problems

    private func messageScreen(
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        systemImage: String,
        actionTitle: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .safeAreaInset(edge: .bottom) {
            Button("Change role", action: onChangeRole)
                .font(.footnote)
                .padding(.bottom, DS.Spacing.l)
        }
    }
}

/// A heat or power problem as a glass card, shown even on the black screen so it is seen
/// from across the room.
private struct HealthWarningCard: View {
    let warning: CameraHealth.Warning
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassCard {
            Label {
                Text(message)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var message: LocalizedStringKey {
        switch warning {
        case .overheating: "This phone is hot. Video slows down until it cools."
        case .lowBattery: "Battery low. Plug this phone in."
        case .unplugged: "Plug this phone in so it stays on."
        case .offline: "No internet connection."
        }
    }

    private var symbol: String {
        switch warning {
        case .overheating: "thermometer.high"
        case .lowBattery: "battery.25"
        case .unplugged: "powerplug"
        case .offline: "wifi.slash"
        }
    }
}

/// Groups floating glass controls so their glass blends together on iOS 26.
private struct GlassControlGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: DS.Spacing.m) {
                content
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private extension View {
    /// Glass buttons on iOS 26, bordered buttons before.
    @ViewBuilder
    func cameraControlStyle(prominent: Bool) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            borderedControlStyle(prominent: prominent)
        }
        #else
        borderedControlStyle(prominent: prominent)
        #endif
    }

    @ViewBuilder
    func borderedControlStyle(prominent: Bool) -> some View {
        if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

#Preview {
    CameraModeView {}
}

#Preview("Dark") {
    CameraModeView {}
        .preferredColorScheme(.dark)
}

#Preview("Hebrew (RTL)") {
    CameraModeView {}
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}
