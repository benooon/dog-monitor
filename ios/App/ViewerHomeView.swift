import DogMonitorCore
import SwiftUI
import WidgetKit

/// Viewer home: a card per camera (last snapshot, online, dog state; tap for live view) and the dogs.
struct ViewerHomeView: View {
    let model: ViewerSessionModel
    let householdName: String
    var isOwner = false
    @State private var showsHousehold = false
    @State private var showsNotifications = false
    @State private var showsTimeline = false
    /// The daily summary sheet, opened from the toolbar or a "daily summary is ready" push.
    @State private var summary: SummaryRequest?
    @State private var path: [UUID] = []
    private let router = DeepLinkRouter.shared
    private let liveActivities = CameraLiveActivityController.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if horizontalSizeClass == .regular {
                    cameraGrid
                } else {
                    cameraList
                }
            }
            .overlay {
                if model.household == nil && model.isWorking {
                    ProgressView()
                }
            }
            .navigationTitle(Text(verbatim: model.household?.name ?? householdName))
            .refreshable { await model.loadHousehold() }
            .sheet(isPresented: $showsHousehold, onDismiss: { Task { await model.loadHousehold() } }) {
                HouseholdView(model: model)
            }
            .sheet(isPresented: $showsNotifications) {
                NotificationSettingsView(
                    model: NotificationSettingsModel(api: model.authorizedAPI, cameras: model.household?.cameras ?? []),
                    dogName: model.household?.dogs.first?.name
                )
            }
            .sheet(isPresented: $showsTimeline) {
                ActivityTimelineView(
                    model: TimelineModel(api: model.authorizedAPI, cameras: model.household?.cameras ?? [])
                )
            }
            .sheet(item: $summary) { request in
                DailySummaryView(
                    model: DailySummaryModel(
                        api: model.authorizedAPI,
                        cameras: model.household?.cameras ?? [],
                        cameraId: request.cameraId
                    ),
                    dogName: model.household?.dogs.first?.name
                )
            }
            .onChange(of: router.summaryCameraId, initial: true) { _, cameraId in
                guard let cameraId else { return }
                summary = SummaryRequest(cameraId: cameraId)
                router.summaryCameraId = nil
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
                await liveActivities.activate(api: model.authorizedAPI)
            }
            .onChange(of: model.household) { publishWidgetStatus() }
            .onChange(of: model.realtime?.dogStates) { publishWidgetStatus() }
            .onChange(of: model.realtime?.presence) { publishWidgetStatus() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign out") { model.signOut() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Activity", systemImage: "clock") {
                        showsTimeline = true
                    }
                    .accessibilityIdentifier("activity-timeline")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Daily summary", systemImage: "chart.bar") {
                        summary = SummaryRequest(cameraId: nil)
                    }
                    .accessibilityIdentifier("daily-summary")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Notifications", systemImage: "bell") {
                        showsNotifications = true
                    }
                    .accessibilityIdentifier("notification-settings")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Household", systemImage: "person.2") {
                        showsHousehold = true
                    }
                    .accessibilityIdentifier("household")
                }
            }
        }
    }

    /// iPhone and narrow iPad windows: a list of camera cards and the dogs.
    private var cameraList: some View {
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
                    .contextMenu { lockScreenButton(for: camera) }
                    .swipeActions(edge: .leading) { lockScreenButton(for: camera) }
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
    }

    /// Wide iPad windows: camera cards side by side, so several rooms fit on one screen.
    private var cameraGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let message = model.errorMessage {
                    Text(message).foregroundStyle(.red)
                }
                let cameras = model.household?.cameras ?? []
                if cameras.isEmpty && model.household != nil {
                    ContentUnavailableView {
                        Label("Cameras", systemImage: "video")
                    } description: {
                        Text("No cameras yet. Pair a spare iPhone as a camera.")
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                    ForEach(cameras) { camera in
                        NavigationLink(value: camera.id) {
                            CameraCard(
                                camera: camera,
                                snapshot: model.snapshots[camera.id],
                                livePresence: model.realtime?.presence[camera.id],
                                dogState: model.realtime?.dogStates[camera.id] ?? camera.currentDogState
                            )
                            .padding(12)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
                            .contentShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("camera-\(camera.id.uuidString.lowercased())")
                        .contextMenu { lockScreenButton(for: camera) }
                    }
                }
                if let dogs = model.household?.dogs, !dogs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Dogs")
                            .font(.headline)
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
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    /// Hands the latest dog state per camera to the home screen widget.
    private func publishWidgetStatus() {
        guard let household = model.household else { return }
        let now = Date.now
        let snapshots = household.cameras.map { camera in
            DogStatusSnapshot(
                cameraId: camera.id,
                cameraName: camera.name,
                dogName: household.dogs.first?.name,
                state: model.realtime?.dogStates[camera.id] ?? camera.currentDogState,
                online: model.realtime?.presence[camera.id] ?? camera.isOnline(now: now),
                updatedAt: now
            )
        }
        DogStatusStore.save(snapshots)
        WidgetCenter.shared.reloadTimelines(ofKind: DogStatusStore.widgetKind)
    }

    /// Shows or hides the camera's Live Activity (Lock Screen and Dynamic Island).
    @ViewBuilder
    private func lockScreenButton(for camera: DeviceDTO) -> some View {
        if liveActivities.isAvailable {
            if liveActivities.isShowing(camera.id) {
                Button("Hide from Lock Screen", systemImage: "lock.slash") {
                    Task { await liveActivities.stop(cameraId: camera.id) }
                }
                .tint(.secondary)
            } else {
                Button("Show on Lock Screen", systemImage: "lock.iphone") {
                    let content = CameraLiveActivityContent(
                        state: model.realtime?.dogStates[camera.id] ?? camera.currentDogState,
                        online: model.realtime?.presence[camera.id] ?? camera.isOnline(now: .now)
                    )
                    try? liveActivities.start(camera: camera, dogName: model.household?.dogs.first?.name, content: content)
                }
                .tint(.accentColor)
            }
        }
    }
}

/// Which camera the daily summary sheet opens on (nil: the first one).
private struct SummaryRequest: Identifiable {
    let id = UUID()
    let cameraId: UUID?
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
