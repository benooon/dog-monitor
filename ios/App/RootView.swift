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
            CameraModeView { storedRole = "" }
        case nil:
            RolePickerView { storedRole = $0.rawValue }
        }
    }
}

#Preview {
    RootView()
}
