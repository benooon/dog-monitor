import Foundation

// Wire types for the backend API. Field names match the JSON exactly.

public struct UserDTO: Codable, Sendable, Hashable {
    public let id: UUID
    public let name: String?
}

public struct AuthResponse: Codable, Sendable, Hashable {
    public let token: String
    public let user: UserDTO
}

public enum MemberRole: String, Codable, Sendable, Hashable {
    case owner, member
}

public struct HouseholdMembershipDTO: Codable, Sendable, Hashable {
    public let id: UUID
    public let name: String
    public let role: MemberRole
}

public struct MeResponse: Codable, Sendable, Hashable {
    public let user: UserDTO
    public let households: [HouseholdMembershipDTO]
}

public struct CreatedHouseholdDTO: Codable, Sendable, Hashable {
    public let id: UUID
    public let name: String
    public let plan: String
    public let role: MemberRole
}

public struct MemberDTO: Codable, Sendable, Hashable {
    public let userId: UUID
    public let name: String?
    public let role: MemberRole

    public init(userId: UUID, name: String?, role: MemberRole) {
        self.userId = userId
        self.name = name
        self.role = role
    }
}

public struct DogDTO: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let householdId: UUID
    public let name: String
    public let photoKey: String?
    /// Profile from "Meet your dog"; nil/empty until the owner answers (or from older servers).
    public let lifeStage: DogLifeStage?
    public let traits: [DogTrait]
    public let alertStyle: DogAlertStyle?
    /// When the photo (`GET /dogs/:id/photo`) last changed; nil when there is none.
    public let photoUpdatedAt: Date?
    public let createdAt: Date

    public var hasPhoto: Bool { photoUpdatedAt != nil }

    public init(
        id: UUID,
        householdId: UUID,
        name: String,
        photoKey: String? = nil,
        lifeStage: DogLifeStage? = nil,
        traits: [DogTrait] = [],
        alertStyle: DogAlertStyle? = nil,
        photoUpdatedAt: Date? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.householdId = householdId
        self.name = name
        self.photoKey = photoKey
        self.lifeStage = lifeStage
        self.traits = traits
        self.alertStyle = alertStyle
        self.photoUpdatedAt = photoUpdatedAt
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, householdId, name, photoKey, lifeStage, traits, alertStyle, photoUpdatedAt, createdAt
    }

    /// Lenient: profile fields may be missing (older servers) and unknown values are ignored.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        householdId = try c.decode(UUID.self, forKey: .householdId)
        name = try c.decode(String.self, forKey: .name)
        photoKey = try c.decodeIfPresent(String.self, forKey: .photoKey)
        let rawLifeStage: String? = try? c.decodeIfPresent(String.self, forKey: .lifeStage)
        lifeStage = rawLifeStage.flatMap(DogLifeStage.init(rawValue:))
        let rawTraits: [String]? = try? c.decodeIfPresent([String].self, forKey: .traits)
        traits = (rawTraits ?? []).compactMap(DogTrait.init(rawValue:))
        let rawAlertStyle: String? = try? c.decodeIfPresent(String.self, forKey: .alertStyle)
        alertStyle = rawAlertStyle.flatMap(DogAlertStyle.init(rawValue:))
        photoUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .photoUpdatedAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}

public enum DeviceStatus: String, Codable, Sendable, Hashable {
    case active, revoked
}

public struct DeviceDTO: Codable, Sendable, Hashable, Identifiable {
    /// A camera is offline after this long without a heartbeat (SPEC §6).
    public static let offlineAfter: TimeInterval = 3 * 60

    public let id: UUID
    public let householdId: UUID
    public let userId: UUID?
    public let name: String
    public let role: DeviceRole
    public let model: String?
    public let appVersion: String?
    public let hasPushToken: Bool
    public let status: DeviceStatus
    public let lastHeartbeatAt: Date?
    public let battery: Double?
    public let charging: Bool?
    public let thermal: String?
    /// Cameras: the dog's state from the last heartbeat (raw value; unknown values are ignored).
    public let dogState: String?
    /// Cameras: the zone kinds drawn on this camera (raw values; only in `GET /household`).
    public let zoneKinds: [String]?
    public let createdAt: Date

    public init(
        id: UUID,
        householdId: UUID,
        userId: UUID? = nil,
        name: String,
        role: DeviceRole,
        model: String? = nil,
        appVersion: String? = nil,
        hasPushToken: Bool = false,
        status: DeviceStatus = .active,
        lastHeartbeatAt: Date? = nil,
        battery: Double? = nil,
        charging: Bool? = nil,
        thermal: String? = nil,
        dogState: String? = nil,
        zoneKinds: [CameraZone.Kind]? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.householdId = householdId
        self.userId = userId
        self.name = name
        self.role = role
        self.model = model
        self.appVersion = appVersion
        self.hasPushToken = hasPushToken
        self.status = status
        self.lastHeartbeatAt = lastHeartbeatAt
        self.battery = battery
        self.charging = charging
        self.thermal = thermal
        self.dogState = dogState
        self.zoneKinds = zoneKinds?.map(\.rawValue)
        self.createdAt = createdAt
    }

    public var currentDogState: DogState? {
        dogState.flatMap(DogState.init(rawValue:))
    }

    /// The known zone kinds on this camera (unknown values are ignored).
    public var zones: Set<CameraZone.Kind> {
        Set((zoneKinds ?? []).compactMap(CameraZone.Kind.init(rawValue:)))
    }
}

/// The latest snapshot of a camera (`GET /cameras/snapshots`), with a short-lived URL.
public struct CameraSnapshotDTO: Codable, Sendable, Hashable {
    public let cameraId: UUID
    public let eventId: UUID
    public let takenAt: Date
    public let url: URL
}

public struct HouseholdDTO: Codable, Sendable, Hashable {
    public let id: UUID
    public let name: String
    public let plan: String
    public let ownerId: UUID
    public let role: MemberRole
    /// The owner opted in to keep labeled clips for training (nil from older servers).
    public let shareTrainingData: Bool?
    public let members: [MemberDTO]
    public let dogs: [DogDTO]
    public let devices: [DeviceDTO]

    public init(
        id: UUID,
        name: String,
        plan: String = "free",
        ownerId: UUID,
        role: MemberRole,
        shareTrainingData: Bool? = nil,
        members: [MemberDTO] = [],
        dogs: [DogDTO] = [],
        devices: [DeviceDTO] = []
    ) {
        self.id = id
        self.name = name
        self.plan = plan
        self.ownerId = ownerId
        self.role = role
        self.shareTrainingData = shareTrainingData
        self.members = members
        self.dogs = dogs
        self.devices = devices
    }
}

public struct InviteDTO: Codable, Sendable, Hashable {
    /// Long one-time token for the QR code / invite link.
    public let token: String
    /// 6-digit code to type instead of scanning.
    public let code: String
    public let expiresAt: Date

    public init(token: String, code: String, expiresAt: Date) {
        self.token = token
        self.code = code
        self.expiresAt = expiresAt
    }
}

public struct MemberJoinResponse: Codable, Sendable, Hashable {
    public let householdId: UUID
    public let role: MemberRole
}

public struct CameraPairingResponse: Codable, Sendable, Hashable {
    public let householdId: UUID
    public let device: DeviceDTO
    /// Returned only once. Store it in the keychain and use `APICredential.device`.
    public let deviceSecret: String
}

/// What a client needs to join a camera's LiveKit room (`POST /cameras/:id/live-token`, `POST /device/live-token`).
public struct LiveTokenDTO: Codable, Sendable, Hashable {
    /// LiveKit server URL (wss://…).
    public let url: String
    public let token: String
    public let room: String
    public let identity: String
    public let expiresAt: Date
}

/// An event as stored by the backend (`POST /events`, `PATCH /events/:id`).
public struct EventDTO: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let householdId: UUID
    public let cameraId: UUID?
    public let type: EventType
    public let state: DogState?
    public let startedAt: Date
    public let endedAt: Date?
    public let confidence: Double?
    public let clipKey: String?
    public let snapshotKey: String?
    /// A viewer's verdict on the detection (`PUT /events/:id/feedback`); nil until someone answers.
    public let feedback: DogEvent.Feedback?

    public init(
        id: UUID,
        householdId: UUID,
        cameraId: UUID?,
        type: EventType,
        state: DogState? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        confidence: Double? = nil,
        clipKey: String? = nil,
        snapshotKey: String? = nil,
        feedback: DogEvent.Feedback? = nil
    ) {
        self.id = id
        self.householdId = householdId
        self.cameraId = cameraId
        self.type = type
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.confidence = confidence
        self.clipKey = clipKey
        self.snapshotKey = snapshotKey
        self.feedback = feedback
    }
}

/// Body of `POST /events` (camera device auth). The id is generated on the camera so retries are idempotent.
public struct CreateEventRequest: Codable, Sendable, Hashable {
    public var id: UUID
    public var type: EventType
    public var state: DogState?
    public var startedAt: Date
    public var endedAt: Date?
    public var confidence: Double?
    public var clipKey: String?
    public var snapshotKey: String?

    public init(_ event: DogEvent) {
        id = event.id
        type = event.type
        state = event.state
        startedAt = event.startedAt
        endedAt = event.endedAt
        confidence = event.confidence
        clipKey = event.clipKey
        snapshotKey = event.snapshotKey
    }
}

/// Body of `PATCH /events/:id`.
public struct UpdateEventRequest: Codable, Sendable, Hashable {
    public var endedAt: Date?
    public var clipKey: String?
    public var snapshotKey: String?
    /// Sends an escalation push ("barking for 5 minutes").
    public var escalationSeconds: Double?

    public init(endedAt: Date? = nil, clipKey: String? = nil, snapshotKey: String? = nil, escalationSeconds: Double? = nil) {
        self.endedAt = endedAt
        self.clipKey = clipKey
        self.snapshotKey = snapshotKey
        self.escalationSeconds = escalationSeconds
    }
}

public struct HealthResponse: Codable, Sendable, Hashable {
    public let status: String
    public let uptimeSeconds: Double
    public let version: String
}

// MARK: - Requests

public struct AppleSignInRequest: Codable, Sendable, Hashable {
    public var identityToken: String
    /// The raw nonce; its SHA-256 (hex) must have been set on the Apple request.
    public var nonce: String
    public var name: String?

    public init(identityToken: String, nonce: String, name: String? = nil) {
        self.identityToken = identityToken
        self.nonce = nonce
        self.name = name
    }
}

/// Body of `POST /dogs` and `PATCH /dogs/:id`. Fields left nil are not sent (unchanged on PATCH).
public struct DogInput: Codable, Sendable, Hashable {
    public var name: String?
    public var photoKey: String?
    public var lifeStage: DogLifeStage?
    public var traits: [DogTrait]?
    public var alertStyle: DogAlertStyle?

    public init(
        name: String? = nil,
        photoKey: String? = nil,
        lifeStage: DogLifeStage? = nil,
        traits: [DogTrait]? = nil,
        alertStyle: DogAlertStyle? = nil
    ) {
        self.name = name
        self.photoKey = photoKey
        self.lifeStage = lifeStage
        self.traits = traits
        self.alertStyle = alertStyle
    }
}

public struct RegisterDeviceRequest: Codable, Sendable, Hashable {
    public var name: String
    public var role: DeviceRole
    public var model: String?
    public var appVersion: String?
    public var apnsToken: String?
    /// IANA time zone of the phone, for quiet hours.
    public var timeZone: String?

    public init(
        name: String,
        role: DeviceRole,
        model: String? = nil,
        appVersion: String? = nil,
        apnsToken: String? = nil,
        timeZone: String? = nil
    ) {
        self.name = name
        self.role = role
        self.model = model
        self.appVersion = appVersion
        self.apnsToken = apnsToken
        self.timeZone = timeZone
    }
}

public struct UpdateDeviceRequest: Codable, Sendable, Hashable {
    public var name: String?
    public var model: String?
    public var appVersion: String?
    /// Hex-encoded APNs device token.
    public var apnsToken: String?
    /// No pushes to this phone until then ("Mute 1h").
    public var mutedUntil: Date?
    /// IANA time zone of the phone, for quiet hours.
    public var timeZone: String?

    public init(
        name: String? = nil,
        model: String? = nil,
        appVersion: String? = nil,
        apnsToken: String? = nil,
        mutedUntil: Date? = nil,
        timeZone: String? = nil
    ) {
        self.name = name
        self.model = model
        self.appVersion = appVersion
        self.apnsToken = apnsToken
        self.mutedUntil = mutedUntil
        self.timeZone = timeZone
    }
}

struct NameRequest: Encodable {
    let name: String
}

struct AcceptAsMemberRequest: Encodable {
    let `as` = "member"

    enum CodingKeys: String, CodingKey { case `as` }
}

struct AcceptAsCameraRequest: Encodable {
    let `as` = "camera"
    let deviceName: String
    let model: String?
    let appVersion: String?

    enum CodingKeys: String, CodingKey { case `as`, deviceName, model, appVersion }
}

extension DeviceDTO {
    /// Active and heartbeat seen within `offlineAfter`.
    public func isOnline(now: Date) -> Bool {
        guard status == .active, let lastHeartbeatAt else { return false }
        return now.timeIntervalSince(lastHeartbeatAt) < Self.offlineAfter
    }
}

extension HouseholdDTO {
    public var cameras: [DeviceDTO] {
        devices.filter { $0.role == .camera && $0.status == .active }
    }

    /// Whether any active camera has a no-go (forbidden) zone, e.g. around the sofa.
    public var hasForbiddenZone: Bool {
        cameras.contains { $0.zones.contains(.forbidden) }
    }
}

// MARK: - Event media

/// Kinds of event media the camera uploads (`POST /device/uploads`).
public enum MediaKind: String, Codable, Sendable, Hashable, CaseIterable {
    case clip
    case snapshot

    /// File name on the camera and in the bucket.
    public var fileName: String {
        switch self {
        case .clip: "clip.mp4"
        case .snapshot: "snapshot.jpg"
        }
    }
}

/// Body of `POST /device/uploads`. The event id is sent lowercased, the same way it appears in
/// `/events/:id` paths, because the backend derives the media key prefix from it.
public struct MediaUploadsRequest: Codable, Sendable, Hashable {
    public var eventId: String
    public var kinds: [MediaKind]
}

/// A presigned PUT: send the file to `url` with `headers` (no auth header).
public struct PresignedUploadDTO: Codable, Sendable, Hashable {
    public let key: String
    public let url: URL
    public let headers: [String: String]
    public let expiresAt: Date

    public init(key: String, url: URL, headers: [String: String], expiresAt: Date) {
        self.key = key
        self.url = url
        self.headers = headers
        self.expiresAt = expiresAt
    }
}

/// Response of `POST /device/uploads`.
public struct MediaUploadsDTO: Codable, Sendable, Hashable {
    public struct Uploads: Codable, Sendable, Hashable {
        public let clip: PresignedUploadDTO?
        public let snapshot: PresignedUploadDTO?
    }

    public let uploads: Uploads

    public subscript(kind: MediaKind) -> PresignedUploadDTO? {
        switch kind {
        case .clip: uploads.clip
        case .snapshot: uploads.snapshot
        }
    }
}

// MARK: - Notification preferences

/// One stored preference row: an event type for all cameras (`cameraId == nil`) or one camera.
/// Quiet hours are "HH:MM" in the phone's time zone and only hold back non-time-sensitive pushes.
public struct NotificationPrefDTO: Codable, Sendable, Hashable {
    public var cameraId: UUID?
    public var eventType: EventType
    public var enabled: Bool
    public var quietStart: String?
    public var quietEnd: String?

    public init(cameraId: UUID?, eventType: EventType, enabled: Bool, quietStart: String? = nil, quietEnd: String? = nil) {
        self.cameraId = cameraId
        self.eventType = eventType
        self.enabled = enabled
        self.quietStart = quietStart
        self.quietEnd = quietEnd
    }

    private enum CodingKeys: String, CodingKey {
        case cameraId, eventType, enabled, quietStart, quietEnd
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cameraId = try container.decodeIfPresent(UUID.self, forKey: .cameraId)
        eventType = try container.decode(EventType.self, forKey: .eventType)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        quietStart = try container.decodeIfPresent(String.self, forKey: .quietStart)
        quietEnd = try container.decodeIfPresent(String.self, forKey: .quietEnd)
    }

    /// `cameraId` is required by the backend, so `nil` is sent as an explicit `null`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let cameraId {
            try container.encode(cameraId.uuidString.lowercased(), forKey: .cameraId)
        } else {
            try container.encodeNil(forKey: .cameraId)
        }
        try container.encode(eventType, forKey: .eventType)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(quietStart, forKey: .quietStart)
        try container.encodeIfPresent(quietEnd, forKey: .quietEnd)
    }
}

/// How the backend treats an event type when the user has no preference row for it.
public struct NotificationTypeInfoDTO: Codable, Sendable, Hashable {
    public let eventType: EventType
    public let enabledByDefault: Bool
    public let bypassesQuietHours: Bool

    public init(eventType: EventType, enabledByDefault: Bool, bypassesQuietHours: Bool) {
        self.eventType = eventType
        self.enabledByDefault = enabledByDefault
        self.bypassesQuietHours = bypassesQuietHours
    }
}

/// Response of `GET` / `PUT /notification-prefs`.
public struct NotificationPrefsDTO: Codable, Sendable, Hashable {
    public let types: [NotificationTypeInfoDTO]
    public let prefs: [NotificationPrefDTO]

    public init(types: [NotificationTypeInfoDTO], prefs: [NotificationPrefDTO]) {
        self.types = types
        self.prefs = prefs
    }
}

/// Body of `PUT /notification-prefs`: replaces all of the caller's rows.
public struct NotificationPrefsRequest: Encodable, Sendable, Hashable {
    public var prefs: [NotificationPrefDTO]
}
