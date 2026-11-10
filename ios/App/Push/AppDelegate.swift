import DogMonitorCore
import UIKit
import UserNotifications

/// Push plumbing: notification categories, APNs token, and taps on notifications.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([Self.eventCategory])
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistry.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // Expected on the simulator and without the push entitlement; nothing to do.
    }

    static var eventCategory: UNNotificationCategory {
        let watch = UNNotificationAction(
            identifier: PushPayload.Action.watchLive.rawValue,
            title: String(localized: "Watch live"),
            options: [.foreground]
        )
        let mute = UNNotificationAction(
            identifier: PushPayload.Action.mute1h.rawValue,
            title: String(localized: "Mute 1h"),
            options: []
        )
        return UNNotificationCategory(identifier: PushPayload.category, actions: [watch, mute], intentIdentifiers: [], options: [])
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        guard let payload = PushPayload(userInfo: response.notification.request.content.userInfo) else { return }
        if action == PushPayload.Action.mute1h.rawValue {
            // The system keeps the app alive until this returns.
            await PushRegistry.shared.muteForAnHour()
        } else if action == PushPayload.Action.watchLive.rawValue || action == UNNotificationDefaultActionIdentifier {
            await MainActor.run {
                DeepLinkRouter.shared.liveCameraId = payload.cameraId
            }
        }
    }
}
