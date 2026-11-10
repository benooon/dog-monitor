import Foundation

/// What a camera's Live Activity shows. The app's `ActivityAttributes.ContentState` is this type,
/// and the backend sends it as `content-state` in `liveactivity` pushes
/// (backend/src/notifications/live-activity.ts: `{"state": DogState | null, "online": Bool}`).
/// Keep the field names in sync with the backend.
public struct CameraLiveActivityContent: Codable, Sendable, Hashable {
    /// The dog's state, or nil before the camera has classified anything.
    public var state: DogState?
    public var online: Bool

    public init(state: DogState?, online: Bool) {
        self.state = state
        self.online = online
    }

    private enum CodingKeys: String, CodingKey {
        case state, online
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A state from a newer server must not break the activity, so it reads as `.unknown`.
        let raw = try container.decodeIfPresent(String.self, forKey: .state)
        state = raw.map { DogState(rawValue: $0) ?? .unknown }
        online = try container.decode(Bool.self, forKey: .online)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(state, forKey: .state)
        try container.encode(online, forKey: .online)
    }

    /// The state to show: offline cameras and unclassified dogs both read as `.unknown`.
    public var displayState: DogState {
        guard online, let state else { return .unknown }
        return state
    }

    /// Worth drawing attention in the Dynamic Island (mirrors the backend's urgent push priority).
    public var needsAttention: Bool {
        guard online else { return true }
        guard let state else { return false }
        switch state {
        case .barking, .whining, .atDoor, .forbiddenZone: return true
        case .resting, .restless, .notVisible, .unknown: return false
        }
    }
}

/// `PUT /live-activities`: the server-side record for one Live Activity's push token.
public struct LiveActivityRegistrationDTO: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let cameraId: UUID
    public let createdAt: Date

    public init(id: UUID, cameraId: UUID, createdAt: Date) {
        self.id = id
        self.cameraId = cameraId
        self.createdAt = createdAt
    }
}

/// Body of `PUT /live-activities`.
struct LiveActivityRegistrationRequest: Encodable {
    let cameraId: String
    let pushToken: String
}
