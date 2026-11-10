import DogMonitorCore
import SwiftUI

/// Viewer mode entry: onboarding until the user has a household, then the viewer home.
struct ViewerRootView: View {
    @State private var model = ViewerSessionModel()
    let onChangeRole: () -> Void

    var body: some View {
        content
            .task { await model.restore() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .signedOut:
            SignInView(model: model)
                .overlay(alignment: .topLeading) {
                    Button("Change role", action: onChangeRole)
                        .padding()
                }
        case .needsHousehold:
            CreateHouseholdView(model: model)
        case .ready(_, let household):
            // Placeholder until the viewer home (camera list) exists.
            VStack(spacing: 16) {
                Image(systemName: "house.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text(household.name)
                    .font(.title.bold())
                Text("Your household is ready.")
                    .foregroundStyle(.secondary)
                Button("Sign out") { model.signOut() }
            }
            .padding()
        }
    }
}
