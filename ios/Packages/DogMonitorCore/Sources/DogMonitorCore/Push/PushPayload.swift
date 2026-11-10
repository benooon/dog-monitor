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
    /// Short-lived presigned snapshot download (https only), attached by the Notification Service Extension.
    public let snapshotURL: URL?

    public init(eventId: UUID, cameraId: UUID, type: EventType?, snapshotKey: String?, snapshotURL: URL? = nil) {
        self.eventId = eventId
        self.cameraId = cameraId
        self.type = type
        self.snapshotKey = snapshotKey
        self.snapshotURL = snapshotURL
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
        snapshotURL = Self.snapshotURL(in: userInfo)
    }

    /// The snapshot URL if present and https (never fetch arbitrary schemes from a push).
    public static func snapshotURL(in userInfo: [AnyHashable: Any]) -> URL? {
        guard let string = userInfo["snapshotUrl"] as? String,
              let url = URL(string: string),
              url.scheme?.lowercased() == "https",
              url.host != nil
        else { return nil }
        return url
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
