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
                    LiveView(
                        camera: camera,
                        api: model.authorizedAPI,
                        realtime: realtime,
                        dogName: model.household?.dogs.first?.name
                    )
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
                guard !model.isDemo else { return }
                model.startRealtime()
                await model.loadHousehold()
                await PushRegistry.shared.activate(api: model.authorizedAPI)
                await liveActivities.activate(api: model.authorizedAPI)
            }
            .onChange(of: model.household) { statusChanged() }
            .onChange(of: model.realtime?.dogStates) { statusChanged() }
            .onChange(of: model.realtime?.presence) { statusChanged() }
            .toolbar {
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
                    errorLabel(message)
                }
            }
            Section("Cameras") {
                let cameras = model.household?.cameras ?? []
                if cameras.isEmpty && model.household != nil {
                    noCameras
                }
                ForEach(cameras) { camera in
                    NavigationLink(value: camera.id) {
                        CameraCard(
                            camera: camera,
                            snapshot: model.snapshots[camera.id],
                            livePresence: model.realtime?.presence[camera.id],
                            dogState: model.realtime?.dogStates[camera.id] ?? camera.currentDogState,
                            dogName: model.household?.dogs.first?.name
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

    /// Wide iPad windows: big camera cards, with the dogs beside them in landscape and below
    /// them in portrait, so the screen is used instead of leaving it mostly empty.
    private var cameraGrid: some View {
        GeometryReader { proxy in
            let cameras = model.household?.cameras ?? []
            let showsSidebar = proxy.size.width > proxy.size.height
                && proxy.size.width >= Self.sidebarMinScreenWidth
            let gridWidth = proxy.size.width - DS.Spacing.l * 2
                - (showsSidebar ? Self.sidebarWidth + DS.Spacing.l : 0)
            let columnCount = Self.gridColumnCount(
                cameraCount: cameras.count,
                width: gridWidth,
                portrait: !showsSidebar
            )
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.xxl) {
                    if let message = model.errorMessage {
                        errorLabel(message)
                    }
                    if cameras.isEmpty && model.household != nil {
                        noCameras
                    }
                    if showsSidebar {
                        HStack(alignment: .top, spacing: DS.Spacing.l) {
                            cameraCards(cameras, columns: columnCount)
                            dogsPanel
                                .frame(width: Self.sidebarWidth)
                        }
                    } else {
                        cameraCards(cameras, columns: columnCount)
                        dogsPanel
                    }
                }
                .padding(DS.Spacing.l)
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    private func cameraCards(_ cameras: [DeviceDTO], columns: Int) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.l, alignment: .top), count: columns),
            spacing: DS.Spacing.l
        ) {
            ForEach(cameras) { camera in
                NavigationLink(value: camera.id) {
                    CameraCard(
                        camera: camera,
                        snapshot: model.snapshots[camera.id],
                        livePresence: model.realtime?.presence[camera.id],
                        dogState: model.realtime?.dogStates[camera.id] ?? camera.currentDogState,
                        dogName: model.household?.dogs.first?.name
                    )
                    .padding(DS.Spacing.m)
                    .background(Color(.secondarySystemGroupedBackground), in: Self.gridCardShape)
                    .contentShape(Self.gridCardShape)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("camera-\(camera.id.uuidString.lowercased())")
                .contextMenu { lockScreenButton(for: camera) }
            }
        }
    }

    /// The household's dogs as a grouped card, matching the camera cards.
    @ViewBuilder
    private var dogsPanel: some View {
        if let dogs = model.household?.dogs, !dogs.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                Text("Dogs")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ForEach(dogs) { dog in
                    Label {
                        Text(verbatim: dog.name)
                    } icon: {
                        Image(systemName: "pawprint.fill")
                            .foregroundStyle(.tint)
                    }
                    .font(.body)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.l)
            .background(Color(.secondarySystemGroupedBackground), in: Self.gridCardShape)
        }
    }

    /// Columns for the iPad grid. One or two cameras in portrait get one large card each;
    /// otherwise as many columns as fit at the minimum card width, never more than there are cameras.
    static func gridColumnCount(cameraCount: Int, width: CGFloat, portrait: Bool) -> Int {
        if portrait && cameraCount <= 2 { return 1 }
        let fitting = Int((width + DS.Spacing.l) / (gridCardMinWidth + DS.Spacing.l))
        return max(1, min(fitting, max(cameraCount, 1)))
    }

    /// Fresh realtime state or a changed camera list: refresh the widget and any Live Activities.
    private func statusChanged() {
        publishWidgetStatus()
        let dogStates = model.realtime?.dogStates ?? [:]
        let presence = model.realtime?.presence ?? [:]
        let householdCameras = model.household.map { Set($0.cameras.map(\.id)) }
        Task {
            await liveActivities.sync(dogStates: dogStates, presence: presence, householdCameras: householdCameras)
        }
    }

    /// Narrowest a camera card gets in the iPad grid before it wraps to fewer columns.
    private static let gridCardMinWidth: CGFloat = 320
    /// Width of the dogs column beside the cameras in landscape.
    private static let sidebarWidth: CGFloat = 280
    /// Screens narrower than this (split view, small iPads) keep the dogs below the cameras.
    private static let sidebarMinScreenWidth: CGFloat = 960
    private static let gridCardShape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)

    /// The household has no cameras yet; the owner can go straight to pairing one.
    private var noCameras: some View {
        ContentUnavailableView {
            Label("No cameras yet", systemImage: "video.badge.plus")
        } description: {
            Text("Pair a spare iPhone to watch your dog from here.")
        } actions: {
            if isOwner {
                Button("Invite family or pair a camera") {
                    showsHousehold = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func errorLabel(_ message: String) -> some View {
        Label {
            Text(verbatim: message)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.red)
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
    /// Shown on the placeholder before the camera has sent a picture.
    var dogName: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let snapshotShape = RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let online = livePresence ?? camera.isOnline(now: context.date)
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                snapshotView
                    .overlay(alignment: .topLeading) {
                        StatusPill(
                            title: online ? "Online" : "Offline",
                            tint: online ? .green : .secondary
                        )
                        .padding(DS.Spacing.s)
                    }
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                    Text(verbatim: camera.name)
                        .font(.headline)
                    Spacer(minLength: DS.Spacing.s)
                    if online, let dogState, let label = dogState.label {
                        Label {
                            Text(label)
                        } icon: {
                            Image(systemName: dogState.symbol)
                                .contentTransition(.symbolEffect(.replace))
                                // A slow pulse while the dog needs attention; still with Reduce Motion.
                                .symbolEffect(.pulse, options: .repeating, isActive: dogState.isAlerting && !reduceMotion)
                        }
                        .font(.subheadline)
                        .foregroundStyle(dogState.isAlerting ? Color.orange : Color.secondary)
                        .transition(.opacity)
                    }
                }
                .animation(DS.Motion.animation(DS.Motion.standard, reduceMotion: reduceMotion), value: dogState)
            }
            .padding(.vertical, DS.Spacing.xs)
            .accessibilityElement(children: .combine)
        }
    }

    private var snapshotView: some View {
        ZStack {
            if let snapshot {
                Rectangle().fill(.quaternary)
                AsyncImage(url: snapshot) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ProgressView()
                }
                .accessibilityHidden(true)
            } else {
                NoSnapshotPlaceholder(dogName: dogName)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(Self.snapshotShape)
    }
}

/// Stands in for the snapshot until the camera has sent one: a soft accent wash with the
/// dog's name, so a new household looks ready rather than broken.
private struct NoSnapshotPlaceholder: View {
    var dogName: String?

    /// Strength of the accent wash at the top and bottom of the gradient.
    private static let washTop = 0.22
    private static let washBottom = 0.08

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(Self.washTop), Color.accentColor.opacity(Self.washBottom)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: DS.Spacing.xs) {
                Image(systemName: "pawprint.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .padding(.bottom, DS.Spacing.xs)
                    .accessibilityHidden(true)
                if let dogName {
                    Text(verbatim: dogName)
                        .font(.headline)
                }
                Text("No picture yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(DS.Spacing.l)
        }
    }
}

#Preview {
    ViewerHomeView(model: .demo, householdName: "Home", isOwner: true)
}

#Preview("Hebrew (RTL)") {
    ViewerHomeView(model: .demo, householdName: "Home", isOwner: true)
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    ViewerHomeView(model: .demo, householdName: "Home", isOwner: true)
        .preferredColorScheme(.dark)
}
