import DogMonitorCore
import SwiftUI

/// Viewer home: the household's cameras and dogs. Live view and snapshots come later.
struct ViewerHomeView: View {
    let model: ViewerSessionModel
    let householdName: String
    var isOwner = false
    @State private var showsInvite = false

    var body: some View {
        NavigationStack {
            List {
                if let message = model.errorMessage {
                    Section {
                        Text(message).foregroundStyle(.red)
                    }
                }
                Section("Cameras") {
                    let cameras = model.household?.cameras ?? []
                    if cameras.isEmpty {
                        Text("No cameras yet. Pair a spare iPhone as a camera.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(cameras) { camera in
                        CameraRow(camera: camera)
                    }
                }
                if let dogs = model.household?.dogs, !dogs.isEmpty {
                    Section("Dogs") {
                        ForEach(dogs) { dog in
                            Label {
                                Text(verbatim: dog.name)
                            } icon: {
                                Image(systemName: "pawprint.fill")
                            }
                        }
                    }
                }
            }
            .overlay {
                if model.household == nil && model.isWorking {
                    ProgressView()
                }
            }
            .navigationTitle(Text(verbatim: model.household?.name ?? householdName))
            .refreshable { await model.loadHousehold() }
            .sheet(isPresented: $showsInvite, onDismiss: { Task { await model.loadHousehold() } }) {
                InviteSheet(model: model)
            }
            .task { await model.loadHousehold() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign out") { model.signOut() }
                }
                if isOwner {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showsInvite = true
                        } label: {
                            Label("Invite", systemImage: "person.badge.plus")
                        }
                        .accessibilityIdentifier("invite")
                    }
                }
            }
        }
    }
}

private struct CameraRow: View {
    let camera: DeviceDTO

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let online = camera.isOnline(now: context.date)
            HStack {
                Image(systemName: "video.fill")
                    .foregroundStyle(.tint)
                Text(verbatim: camera.name)
                Spacer()
                Circle()
                    .fill(online ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(online ? LocalizedStringKey("Online") : LocalizedStringKey("Offline"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
