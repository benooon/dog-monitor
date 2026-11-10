import DogMonitorCore
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
            Screen(name: "04-viewer-home") {
                AnyView(ViewerHomeView(model: .demo, householdName: "Home", isOwner: true))
            },
            Screen(name: "05-live-view") {
                AnyView(NavigationStack {
                    LiveView(camera: demoCamera, api: sampleAPI, realtime: ViewerRealtime(api: sampleAPI), dogName: "Rex")
                })
            },
            Screen(name: "06-timeline") { AnyView(ActivityTimelineView(model: .preview)) },
            Screen(name: "07-event-detail") {
                let model = TimelineModel.preview
                return AnyView(NavigationStack {
                    EventDetailView(model: model, eventId: model.feed.events[1].id)
                })
            },
            Screen(name: "08-daily-summary") { AnyView(DailySummaryView(model: .preview, dogName: "Rex")) },
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
            Screen(name: "13-premium") {
                AnyView(PremiumView(model: SubscriptionModel(api: sampleAPI, householdId: UUID())))
            },
        ]
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

        for screen in Self.screens {
            for variant in Variant.allCases {
                let image = try await render(screen.make(), variant: variant, in: scene)
                let file = output.appendingPathComponent("\(device)-\(screen.name)-\(variant.rawValue).png")
                try XCTUnwrap(image.pngData()).write(to: file)
            }
        }
    }

    private func render(_ view: AnyView, variant: Variant, in scene: UIWindowScene) async throws -> UIImage {
        let rooted = view
            .environment(\.locale, Locale(identifier: variant == .hebrew ? "he" : "en"))
            .environment(\.layoutDirection, variant == .hebrew ? .rightToLeft : .leftToRight)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = variant == .dark ? .dark : .light
        window.rootViewController = UIHostingController(rootView: rooted)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        // Let layout, .task work, async images and symbol transitions settle.
        try await Task.sleep(for: .seconds(1.5))
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }
}
