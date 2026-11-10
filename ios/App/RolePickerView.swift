import DogMonitorCore
import SwiftUI

/// First screen: choose whether this device is a camera or a viewer.
struct RolePickerView: View {
    let onSelect: (DeviceRole) -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "pawprint.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Dog Monitor")
                .font(.largeTitle.bold())
            Text("How will this device be used?")
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            ForEach(DeviceRole.allCases, id: \.self) { role in
                Button {
                    onSelect(role)
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: role.systemImage)
                            .font(.title2)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(role.title)
                                .font(.headline)
                            Text(role.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("role-\(role.rawValue)")
            }
            Spacer()
        }
        .padding()
    }
}

#Preview {
    RolePickerView { _ in }
}

#Preview("Hebrew (RTL)") {
    RolePickerView { _ in }
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}
