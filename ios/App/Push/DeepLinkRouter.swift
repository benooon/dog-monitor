import Foundation
import Observation

/// Where a notification tap should take the viewer (e.g. a camera's live view).
@MainActor
@Observable
final class DeepLinkRouter {
    static let shared = DeepLinkRouter()

    /// Set by a notification tap; the viewer home opens this camera's live view and clears it.
    var liveCameraId: UUID?
}
