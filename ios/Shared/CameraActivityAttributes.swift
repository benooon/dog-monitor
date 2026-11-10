import ActivityKit
import DogMonitorCore
import Foundation

/// A camera's Live Activity on a viewer's phone. Shared by the app (which starts it) and the
/// widget extension (which draws it). The backend updates `ContentState` with `liveactivity`
/// pushes, so it is `CameraLiveActivityContent` from core, kept in sync with the server.
struct CameraActivityAttributes: ActivityAttributes, Sendable {
    typealias ContentState = CameraLiveActivityContent

    let cameraId: UUID
    let cameraName: String
    /// Shown as the title when we know it.
    let dogName: String?
}
