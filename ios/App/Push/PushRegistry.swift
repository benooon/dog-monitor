import DogMonitorCore
import Foundation
import os
import UIKit
import UserNotifications

/// Registers this viewer phone for push and keeps its APNs token on the backend device record.
@MainActor
final class PushRegistry {
    static let shared = PushRegistry()

    private static let deviceIdKey = "viewerDeviceId"
    private let logger = Logger(subsystem: "com.benooon.dogmonitor", category: "Push")
    private var token: String?
    private var api: DogMonitorAPI?

    /// The backend id of this phone's viewer device, once registered.
    var deviceId: UUID? {
        UserDefaults.standard.string(forKey: Self.deviceIdKey).flatMap(UUID.init(uuidString:))
    }

    /// Called when the viewer is signed in with a household: asks for permission (once) and registers.
    func activate(api: DogMonitorAPI) async {
        self.api = api
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else { return }
            UIApplication.shared.registerForRemoteNotifications()
        } catch {
            logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
        }
        await sync()
    }

    func deactivate() {
        api = nil
        UserDefaults.standard.removeObject(forKey: Self.deviceIdKey)
    }

    func didRegister(deviceToken: Data) {
        token = PushToken.hex(deviceToken)
        Task { await sync() }
    }

    /// "Mute 1h" from a notification: silence pushes to this phone on the server.
    func muteForAnHour() async {
        guard let deviceId else { return }
        let api = self.api ?? DogMonitorAPI(baseURL: AppConfig.apiBaseURL, credential: CredentialStore(store: KeychainStore()).load())
        do {
            _ = try await api.updateDevice(id: deviceId, UpdateDeviceRequest(mutedUntil: PushMute.until(from: .now)))
        } catch {
            logger.error("Mute failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Creates or updates the viewer device so the backend has the current token.
    private func sync() async {
        guard let api, let token else { return }
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if let deviceId {
            do {
                _ = try await api.updateDevice(id: deviceId, UpdateDeviceRequest(appVersion: appVersion, apnsToken: token))
                return
            } catch APIError.http(status: 404, _), APIError.http(status: 409, _) {
                // Removed or revoked on the server: register again below.
            } catch {
                logger.error("Token update failed: \(String(describing: error), privacy: .public)")
                return
            }
        }
        do {
            let device = try await api.registerDevice(RegisterDeviceRequest(
                name: UIDevice.current.name,
                role: .viewer,
                model: UIDevice.current.model,
                appVersion: appVersion,
                apnsToken: token
            ))
            UserDefaults.standard.set(device.id.uuidString, forKey: Self.deviceIdKey)
        } catch {
            logger.error("Device registration failed: \(String(describing: error), privacy: .public)")
        }
    }
}
