import Foundation

/// The custom fields of an event push (see `backend/src/notifications/payload.ts`).
public struct PushPayload: Sendable, Equatable {
    /// Category registered by the app; its actions are `Action`.
    public static let category = "DOG_EVENT"

    public enum Action: String, Sendable, CaseIterable {
        case watchLive = "WATCH_LIVE"
        case mute1h = "MUTE_1H"
    }

    public let eventId: UUID
    public let cameraId: UUID
    public let type: EventType?
    public let snapshotKey: String?

    public init(eventId: UUID, cameraId: UUID, type: EventType?, snapshotKey: String?) {
        self.eventId = eventId
        self.cameraId = cameraId
        self.type = type
        self.snapshotKey = snapshotKey
    }

    /// Parses `UNNotificationContent.userInfo`; nil for pushes that aren't event pushes.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let eventId = (userInfo["eventId"] as? String).flatMap(UUID.init(uuidString:)),
              let cameraId = (userInfo["cameraId"] as? String).flatMap(UUID.init(uuidString:))
        else { return nil }
        self.eventId = eventId
        self.cameraId = cameraId
        type = (userInfo["type"] as? String).flatMap(EventType.init(rawValue:))
        snapshotKey = userInfo["snapshotKey"] as? String
    }
}

public enum PushToken {
    /// APNs device token bytes as the lowercase hex string the backend expects.
    public static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}

/// How long "Mute 1h" silences pushes on this phone.
public enum PushMute {
    public static let duration: TimeInterval = 60 * 60

    public static func until(from now: Date) -> Date {
        now.addingTimeInterval(duration)
    }
}
