import DogMonitorCore
import SwiftUI

/// Owner only: cameras that can't go live until they scan the owner's invite code, because the
/// household's live key was replaced after someone left or they were paired without it.
struct LiveKeyNeededSection: View {
    let cameras: [DeviceDTO]
    let showInvite: () -> Void

    var body: some View {
        Section {
            Label {
                if cameras.count == 1, let camera = cameras.first {
                    Text("\(camera.name) needs to scan your invite code before anyone can watch live.")
                } else {
                    Text("\(cameras.count) cameras need to scan your invite code before anyone can watch live.")
                }
            } icon: {
                Image(systemName: "qrcode.viewfinder")
                    .foregroundStyle(.tint)
            }
            Button("Show invite code", systemImage: "qrcode", action: showInvite)
                .accessibilityIdentifier("household-show-invite-for-live-key")
        } footer: {
            Text("On the camera, stop it and tap Scan invite code.")
        }
    }
}

#Preview("One camera") {
    List {
        LiveKeyNeededSection(cameras: [HouseholdDTO.demo.cameras[1]]) {}
    }
}

#Preview("Hebrew, dark") {
    List {
        LiveKeyNeededSection(cameras: HouseholdDTO.demo.cameras) {}
    }
    .environment(\.locale, Locale(identifier: "he"))
    .environment(\.layoutDirection, .rightToLeft)
    .preferredColorScheme(.dark)
}
