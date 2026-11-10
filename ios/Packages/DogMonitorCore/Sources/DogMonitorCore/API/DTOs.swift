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
}

public struct DogDTO: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let householdId: UUID
    public let name: String
    public let photoKey: String?
    public let createdAt: Date
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
    public let createdAt: Date

    public var currentDogState: DogState? {
        dogState.flatMap(DogState.init(rawValue:))
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
    public let members: [MemberDTO]
    public let dogs: [DogDTO]
    public let devices: [DeviceDTO]
}

public struct InviteDTO: Codable, Sendable, Hashable {
    /// Long one-time token for the QR code / invite link.
    public let token: String
    /// 6-digit code to type instead of scanning.
    public let code: String
    public let expiresAt: Date
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

public struct DogInput: Codable, Sendable, Hashable {
    public var name: String?
    public var photoKey: String?

    public init(name: String? = nil, photoKey: String? = nil) {
        self.name = name
        self.photoKey = photoKey
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
}
