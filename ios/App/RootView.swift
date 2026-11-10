import DogMonitorCore
import SwiftUI

/// Shows the role picker until this device has a role, then the matching home screen.
struct RootView: View {
    @AppStorage("deviceRole") private var storedRole: String = ""

    var body: some View {
        switch DeviceRole(rawValue: storedRole) {
        case .viewer:
            ViewerRootView { storedRole = "" }
        case .camera:
            RoleHomeView(role: .camera) { storedRole = "" }
        case nil:
            RolePickerView { storedRole = $0.rawValue }
        }
    }
}

/// Placeholder until camera mode and viewer mode exist.
struct RoleHomeView: View {
    let role: DeviceRole
    let onChangeRole: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: role.systemImage)
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(role.title)
                .font(.title.bold())
            Button("Change role", action: onChangeRole)
        }
        .padding()
    }
}

#Preview {
    RootView()
}
