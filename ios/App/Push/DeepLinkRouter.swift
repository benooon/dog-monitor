import DogMonitorCore
import Foundation
import Observation

/// Where a notification tap should take the viewer (e.g. a camera's live view).
@MainActor
@Observable
final class DeepLinkRouter {
    static let shared = DeepLinkRouter()

    /// Set by a notification tap; the viewer home opens this camera's live view and clears it.
    var liveCameraId: UUID?

    /// Set by tapping a "daily summary is ready" push; the viewer home opens that camera's summary.
    var summaryCameraId: UUID?

    /// An invite token from a tapped invite link; the join screen fills it in and clears it.
    var pendingInvite: String?

    /// Universal Links (`https://<api host>/invite/<token>`) and `dogmonitor://pair?t=…`.
    func handle(_ url: URL) {
        if let token = PairingCode.parse(url.absoluteString) {
            pendingInvite = token
        }
    }
}
