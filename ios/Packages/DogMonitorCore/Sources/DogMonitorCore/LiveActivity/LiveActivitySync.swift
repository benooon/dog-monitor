import Foundation

/// Decides how the Live Activities showing on a viewer's phone should change when the realtime
/// channel reports something new, so the app can update them right away instead of waiting for
/// the backend's `liveactivity` push.
public enum LiveActivitySync {
    public struct Plan: Sendable, Equatable {
        /// New content per camera, only for activities whose content actually changes.
        public var updates: [UUID: CameraLiveActivityContent]
        /// Cameras that are no longer in the household, whose activities should end.
        public var ends: Set<UUID>

        public init(updates: [UUID: CameraLiveActivityContent] = [:], ends: Set<UUID> = []) {
            self.updates = updates
            self.ends = ends
        }

        public var isEmpty: Bool { updates.isEmpty && ends.isEmpty }
    }

    /// - Parameters:
    ///   - showing: the content each showing activity has now, by camera.
    ///   - dogStates: the latest dog state per camera from the realtime channel. A camera missing
    ///     here keeps its current state (the channel only reports states it knows).
    ///   - presence: the latest online flag per camera. A camera missing here keeps its value.
    ///   - householdCameras: the household's cameras, or nil while the household isn't loaded
    ///     (then nothing ends, since an unloaded list says nothing about unpairing).
    public static func plan(
        showing: [UUID: CameraLiveActivityContent],
        dogStates: [UUID: DogState],
        presence: [UUID: Bool],
        householdCameras: Set<UUID>?
    ) -> Plan {
        var plan = Plan()
        for (cameraId, current) in showing {
            if let householdCameras, !householdCameras.contains(cameraId) {
                plan.ends.insert(cameraId)
                continue
            }
            var next = current
            if let state = dogStates[cameraId] {
                next.state = state
            }
            if let online = presence[cameraId] {
                next.online = online
            }
            if next != current {
                plan.updates[cameraId] = next
            }
        }
        return plan
    }
}
