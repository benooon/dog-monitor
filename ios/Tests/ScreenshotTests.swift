import DogMonitorCore
import StoreKitTest
import SwiftUI
import UIKit
import XCTest
@testable import DogMonitor

/// Renders the main screens with sample data to PNGs so people (and agents without Xcode) can
/// see the UI. CI sets `TEST_RUNNER_SCREENSHOT_DIR`; without it the test is skipped.
/// Each screen is shot in light, dark and Hebrew (RTL), at the running device's size.
@MainActor
final class ScreenshotTests: XCTestCase {
    private struct Screen {
        let name: String
        /// How long to let layout, `.task` work and async images settle before the shot.
        var settle: Duration = .seconds(1.5)
        let make: @MainActor () -> AnyView
    }

    private enum Variant: String, CaseIterable {
        case light, dark, hebrew
    }

    private static var screens: [Screen] {
        let sampleAPI = DogMonitorAPI(baseURL: URL(string: "https://example.invalid")!)
        let demoCamera = HouseholdDTO.demo.cameras[0]
        return [
            Screen(name: "01-role-picker") { AnyView(RolePickerView { _ in }) },
            Screen(name: "02-sign-in") {
                AnyView(SignInView(model: ViewerSessionModel(baseURL: sampleAPI.baseURL, store: InMemorySecureStore())))
            },
            Screen(name: "03-create-household") {
                AnyView(CreateHouseholdView(model: ViewerSessionModel(baseURL: sampleAPI.baseURL, store: InMemorySecureStore())))
            },
            Screen(name: "03a-meet-dog-name") { meetDog([]) },
            Screen(name: "03b-meet-dog-photo") { meetDog([.photo]) },
            Screen(name: "03c-meet-dog-age") { meetDog([.photo, .age]) },
            Screen(name: "03d-meet-dog-alone") { meetDog([.photo, .age, .alone]) },
            Screen(name: "03e-meet-dog-alerts") { meetDog([.photo, .age, .alone, .alerts]) },
            Screen(name: "03f-meet-dog-summary") { meetDog([.photo, .age, .alone, .alerts, .summary]) },
            Screen(name: "03g-mark-sofa") { AnyView(MarkSofaSheet(dogName: "Rex")) },
            Screen(name: "03h-photo-crop") { AnyView(PhotoCropView(image: DogPhotoStore.samplePortrait()) { _ in }) },
            Screen(name: "04-viewer-home") {
                AnyView(ViewerHomeView(model: .demo, householdName: "Home", isOwner: true))
            },
            Screen(name: "05-live-view") {
                AnyView(NavigationStack {
                    LiveView(camera: demoCamera, api: sampleAPI, realtime: ViewerRealtime(api: sampleAPI), dogName: "Rex")
                })
            },
            Screen(name: "05a-live-view-needs-key") { liveView(.needsLiveKey, camera: demoCamera, api: sampleAPI) },
            Screen(name: "05b-live-view-wrong-key") { liveView(.wrongLiveKey, camera: demoCamera, api: sampleAPI) },
            Screen(name: "05c-live-view-camera-needs-key") { liveView(.cameraNeedsKey, camera: demoCamera, api: sampleAPI) },
            Screen(name: "05d-live-key-scan") { AnyView(LiveKeyScanView(onKey: { _ in }, fixedCameraAccess: false)) },
            Screen(name: "05e-camera-start-needs-key") {
                AnyView(CameraModeView(model: .preview(liveNeedsKey: true)) {})
            },
            Screen(name: "06-timeline") { AnyView(ActivityTimelineView(model: .preview)) },
            Screen(name: "07-event-detail") {
                let model = TimelineModel.preview
                return AnyView(NavigationStack {
                    EventDetailView(model: model, eventId: model.feed.events[1].id)
                })
            },
            Screen(name: "07a-event-clip-expired") {
                let model = TimelineModel.preview
                let expired = model.feed.events.first { $0.mediaExpired == true }!
                return AnyView(NavigationStack {
                    EventDetailView(model: model, eventId: expired.id)
                })
            },
            Screen(name: "08-daily-summary") { AnyView(DailySummaryView(model: .preview, dogName: "Rex")) },
            Screen(name: "08a-daily-summary-reel", settle: .seconds(2.5)) {
                AnyView(DailySummaryView(model: reelSummaryModel(), dogName: "Rex"))
            },
            Screen(name: "08b-weekly-insights", settle: .seconds(2.5)) {
                AnyView(NavigationStack {
                    List { WeeklyInsightsSection(model: .preview, dogName: "Rex") }
                })
            },
            Screen(name: "08c-vet-report", settle: .seconds(1)) {
                AnyView(GeometryReader { proxy in
                    let page = VetReportPDF.pageSize
                    VetReportPage(report: DailySummaryModel.preview.vetReport, dogName: "Rex", cameraName: "Living room")
                        .frame(width: page.width, height: page.height)
                        .environment(\.colorScheme, .light)
                        .scaleEffect(min(1, proxy.size.width / page.width), anchor: .top)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                })
            },
            Screen(name: "09-household") { AnyView(HouseholdView(model: .demo)) },
            Screen(name: "09a-dog-profile") {
                AnyView(NavigationStack {
                    DogProfileEditor(
                        dog: HouseholdDTO.demo.dogs[0],
                        api: sampleAPI,
                        storedPhoto: DogPhotoStore.samplePortrait()
                    ) { _, _ in }
                })
            },
            Screen(name: "10-invite") {
                AnyView(InviteSheet(
                    model: .demo,
                    invite: InviteDTO(token: "screenshot", code: "482913", expiresAt: .now.addingTimeInterval(9 * 60 + 42))
                ))
            },
            Screen(name: "11-notifications") { AnyView(NotificationSettingsView(model: .preview, dogName: "Rex")) },
            Screen(name: "12-camera-notifications") {
                AnyView(NavigationStack {
                    CameraNotificationsView(model: .preview, camera: demoCamera, dogName: "Rex")
                })
            },
            // The store loads its products from the StoreKit test session, which can take a few seconds.
            Screen(name: "13-premium", settle: .seconds(6)) {
                AnyView(PremiumView(model: SubscriptionModel(api: sampleAPI, householdId: UUID()), dogName: "Rex"))
            },
            Screen(name: "13a-premium-unavailable") {
                AnyView(PremiumView(model: SubscriptionModel(api: sampleAPI, householdId: UUID()) { _ in .init(count: 0) }, dogName: "Rex"))
            },
        ]
    }

    /// Yesterday with a highlight reel: the bundled sample clip goes where the model caches downloads.
    private static func reelSummaryModel() -> DailySummaryModel {
        let model = DailySummaryModel.preview(reelOnDaysAgo: 1)
        if let summary = model.selectedSummary,
           let sample = Bundle(for: ScreenshotTests.self).url(forResource: "sample-reel", withExtension: "mp4") {
            let target = DailySummaryModel.reelCacheURL(for: summary)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: sample, to: target)
        }
        return model
    }

    /// Live view held in one state (it never connects).
    private static func liveView(_ phase: LiveViewModel.Phase, camera: DeviceDTO, api: DogMonitorAPI) -> AnyView {
        let realtime = ViewerRealtime(api: api)
        let model = LiveViewModel.fixed(phase, cameraId: camera.id, api: api, realtime: realtime)
        return AnyView(NavigationStack {
            LiveView(camera: camera, model: model, realtime: realtime, dogName: "Rex")
        })
    }

    /// "Meet your dog" at a given step, with sample answers for Rex.
    private static func meetDog(_ path: [DogOnboardingModel.Step]) -> AnyView {
        AnyView(DogOnboardingView(model: .preview(), initialPath: path, autofocus: false, onSkip: {}, onFinish: {}))
    }

    func testCaptureScreens() async throws {
        let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] ?? ""
        guard !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_SCREENSHOT_DIR to capture screenshots.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "The test host app has no window scene."
        )
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        // Products for the Premium store come from the local StoreKit file.
        let storeSession = try? SKTestSession(configurationFileNamed: "DogMonitor")
        storeSession?.disableDialogs = true
        defer { _ = storeSession }

        for screen in Self.screens {
            for variant in Variant.allCases {
                let image = try await render(screen.make(), variant: variant, settle: screen.settle, in: scene)
                let file = output.appendingPathComponent("\(device)-\(screen.name)-\(variant.rawValue).png")
                try XCTUnwrap(image.pngData()).write(to: file)
            }
        }
    }

    private func render(_ view: AnyView, variant: Variant, settle: Duration, in scene: UIWindowScene) async throws -> UIImage {
        let rooted = view
            .environment(\.locale, Locale(identifier: variant == .hebrew ? "he" : "en"))
            .environment(\.layoutDirection, variant == .hebrew ? .rightToLeft : .leftToRight)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = variant == .dark ? .dark : .light
        window.rootViewController = UIHostingController(rootView: rooted)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        // Let layout, .task work, async images and symbol transitions settle.
        try await Task.sleep(for: settle)
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }
}
