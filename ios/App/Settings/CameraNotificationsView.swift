import DogMonitorCore
import SwiftUI

/// Alerts for one camera; anything left matching the household settings follows them.
struct CameraNotificationsView: View {
    @Bindable var model: NotificationSettingsModel
    let camera: DeviceDTO
    let dogName: String?

    var body: some View {
        Form {
            ForEach(NotificationSettings.Group.allCases, id: \.self) { group in
                Section {
                    ForEach(group.eventTypes, id: \.self) { type in
                        Toggle(isOn: $model.settings[enabled: type, camera: camera.id]) {
                            Label(type.notificationTitle, systemImage: type.notificationSymbol)
                        }
                    }
                } header: {
                    group.header(dogName: dogName)
                }
            }

            Section {
                Button("Use household settings") {
                    model.settings.resetOverrides(camera: camera.id)
                }
                .disabled(model.overriddenTypes(for: camera).isEmpty)
            } footer: {
                Text("These choices apply only to this camera.")
            }
        }
        .navigationTitle(Text(verbatim: camera.name))
    }
}

#Preview {
    NavigationStack {
        CameraNotificationsView(model: .preview, camera: .previewCamera, dogName: "Rex")
    }
}

#Preview("Hebrew (RTL)") {
    NavigationStack {
        CameraNotificationsView(model: .preview, camera: .previewCamera, dogName: "רקס")
    }
    .environment(\.locale, Locale(identifier: "he"))
    .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    NavigationStack {
        CameraNotificationsView(model: .preview, camera: .previewCamera, dogName: nil)
    }
    .preferredColorScheme(.dark)
}
