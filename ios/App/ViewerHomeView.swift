import DogMonitorCore
import SwiftUI

/// Viewer home: a card per camera (last snapshot, online, dog state; tap for live view) and the dogs.
struct ViewerHomeView: View {
    let model: ViewerSessionModel
    let householdName: String
    var isOwner = false
    @State private var showsInvite = false
    @State private var path: [UUID] = []
    private let router = DeepLinkRouter.shared

    var body: some View {
        NavigationStack(path: $path) {
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
                        NavigationLink(value: camera.id) {
                            CameraCard(
                                camera: camera,
                                snapshot: model.snapshots[camera.id],
                                livePresence: model.realtime?.presence[camera.id],
                                dogState: model.realtime?.dogStates[camera.id] ?? camera.currentDogState
                            )
                        }
                        .accessibilityIdentifier("camera-\(camera.id.uuidString.lowercased())")
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
            .navigationDestination(for: UUID.self) { cameraId in
                if let camera = model.household?.cameras.first(where: { $0.id == cameraId }), let realtime = model.realtime {
                    LiveView(camera: camera, api: model.authorizedAPI, realtime: realtime)
                } else {
                    ProgressView()
                }
            }
            .onChange(of: router.liveCameraId, initial: true) { _, cameraId in
                // Opened from a notification ("Watch live" or a tap).
                guard let cameraId else { return }
                path = [cameraId]
                router.liveCameraId = nil
            }
            .task {
                model.startRealtime()
                await model.loadHousehold()
                await PushRegistry.shared.activate(api: model.authorizedAPI)
            }
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

/// One camera: last snapshot, name, online status and the dog's current state.
private struct CameraCard: View {
    let camera: DeviceDTO
    let snapshot: URL?
    /// Presence from the realtime channel, which is fresher than the last heartbeat time.
    var livePresence: Bool?
    var dogState: DogState?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let online = livePresence ?? camera.isOnline(now: context.date)
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    Rectangle().fill(.quaternary)
                    if let snapshot {
                        AsyncImage(url: snapshot) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            ProgressView()
                        }
                    } else {
                        Image(systemName: "video.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(online ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(online ? LocalizedStringKey("Online") : LocalizedStringKey("Offline"))
                    }
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .padding(8)
                }
                HStack {
                    Text(verbatim: camera.name)
                        .font(.headline)
                    Spacer()
                    if online, let label = dogState?.label {
                        Text(label)
                            .font(.subheadline)
                            .foregroundStyle(dogState?.isAlerting == true ? Color.orange : Color.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }
}
