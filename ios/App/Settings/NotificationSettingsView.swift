import DogMonitorCore
import SwiftUI

/// Which alerts this viewer gets: per event type, quiet hours, and per-camera choices.
struct NotificationSettingsView: View {
    @State private var model: NotificationSettingsModel
    let dogName: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: NotificationSettingsModel, dogName: String?) {
        _model = State(initialValue: model)
        self.dogName = dogName
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Notifications")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .navigationDestination(for: UUID.self) { cameraId in
                    if let camera = model.cameras.first(where: { $0.id == cameraId }) {
                        CameraNotificationsView(model: model, camera: camera, dogName: dogName)
                    }
                }
                .alert("Couldn't save your settings", isPresented: $model.saveFailed) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Check your connection and try again.")
                }
                .sensoryFeedback(.error, trigger: model.saveFailed) { _, failed in failed }
                .interactiveDismissDisabled(model.hasChanges)
        }
        .task {
            if model.phase != .ready { await model.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
        case .failed:
            ContentUnavailableView {
                Label("Couldn't load your settings", systemImage: "bell.slash")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try again") {
                    Task { await model.load() }
                }
                .buttonStyle(.borderedProminent)
            }
        case .ready:
            form
        }
    }

    private var form: some View {
        Form {
            ForEach(NotificationSettings.Group.allCases, id: \.self) { group in
                Section {
                    ForEach(group.eventTypes, id: \.self) { type in
                        Toggle(isOn: $model.settings[enabled: type]) {
                            Label(type.notificationTitle, systemImage: type.notificationSymbol)
                        }
                    }
                } header: {
                    group.header(dogName: dogName)
                }
            }

            Section {
                Toggle(isOn: $model.settings.isQuietHoursOn) {
                    Label("Quiet hours", systemImage: "moon")
                }
                if model.settings.isQuietHoursOn {
                    DatePicker("Starts", selection: $model.settings.quietStartDate, displayedComponents: .hourAndMinute)
                    DatePicker("Ends", selection: $model.settings.quietEndDate, displayedComponents: .hourAndMinute)
                }
            } footer: {
                Text("During quiet hours, only barking, whining and camera alerts come through.")
            }

            if !model.cameras.isEmpty {
                Section {
                    ForEach(model.cameras) { camera in
                        NavigationLink(value: camera.id) {
                            LabeledContent {
                                if !model.overriddenTypes(for: camera).isEmpty {
                                    Text("Custom")
                                }
                            } label: {
                                Label {
                                    Text(verbatim: camera.name)
                                } icon: {
                                    Image(systemName: "video")
                                }
                            }
                        }
                    }
                } header: {
                    Text("Cameras")
                } footer: {
                    Text("Choose different alerts for one camera.")
                }
            }
        }
        .animation(DS.Motion.animation(DS.Motion.standard, reduceMotion: reduceMotion), value: model.settings.isQuietHoursOn)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            if model.isSaving {
                ProgressView()
            } else {
                Button("Save") {
                    Task {
                        if await model.save() { dismiss() }
                    }
                }
                .disabled(!model.hasChanges)
            }
        }
    }
}

#Preview {
    NotificationSettingsView(model: .preview, dogName: "Rex")
}

#Preview("Hebrew (RTL)") {
    NotificationSettingsView(model: .preview, dogName: "רקס")
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    NotificationSettingsView(model: .preview, dogName: nil)
        .preferredColorScheme(.dark)
}

extension NotificationSettingsModel {
    /// Sample settings for previews: defaults plus quiet hours, no network.
    static var preview: NotificationSettingsModel {
        let types = EventType.allCases.map {
            NotificationTypeInfoDTO(
                eventType: $0,
                enabledByDefault: $0.isEnabledByDefault,
                bypassesQuietHours: $0.interruptionLevel == .timeSensitive
            )
        }
        let prefs = [NotificationPrefDTO(cameraId: nil, eventType: .calmedDown, enabled: true, quietStart: "22:00", quietEnd: "07:00")]
        return NotificationSettingsModel(
            api: DogMonitorAPI(baseURL: URL(string: "http://localhost:1")!),
            cameras: [],
            loaded: NotificationPrefsDTO(types: types, prefs: prefs)
        )
    }
}
