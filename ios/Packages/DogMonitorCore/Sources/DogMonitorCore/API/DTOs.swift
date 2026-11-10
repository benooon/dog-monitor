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
    public let createdAt: Date
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

public struct HealthResponse: Codable, Sendable, Hashable {
    public let status: String
    public let uptimeSeconds: Double
    public let version: String
}

// MARK: - Requests

public struct AppleSignInRequest: Codable, Sendable, Hashable {
    public var identityToken: String
    public var name: String?

    public init(identityToken: String, name: String? = nil) {
        self.identityToken = identityToken
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

    public init(name: String, role: DeviceRole, model: String? = nil, appVersion: String? = nil, apnsToken: String? = nil) {
        self.name = name
        self.role = role
        self.model = model
        self.appVersion = appVersion
        self.apnsToken = apnsToken
    }
}

public struct UpdateDeviceRequest: Codable, Sendable, Hashable {
    public var name: String?
    public var model: String?
    public var appVersion: String?
    /// Hex-encoded APNs device token.
    public var apnsToken: String?

    public init(name: String? = nil, model: String? = nil, appVersion: String? = nil, apnsToken: String? = nil) {
        self.name = name
        self.model = model
        self.appVersion = appVersion
        self.apnsToken = apnsToken
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
