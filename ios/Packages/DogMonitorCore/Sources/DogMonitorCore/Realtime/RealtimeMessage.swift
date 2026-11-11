import Foundation

/// Messages on the realtime WebSocket (`GET /ws`), mirroring `backend/src/realtime/protocol.ts`.
public enum RealtimeServerMessage: Sendable, Equatable {
    public enum ViewerChange: String, Codable, Sendable {
        case joined
        case left
    }

    public struct CameraPresence: Codable, Sendable, Equatable {
        public let id: UUID
        public let online: Bool
        /// Raw dog state, if the camera reported one.
        public let state: String?

        public init(id: UUID, online: Bool, state: String? = nil) {
            self.id = id
            self.online = online
            self.state = state
        }

        public var dogState: DogState? {
            state.flatMap(DogState.init(rawValue:))
        }
    }

    /// To cameras: how many viewers watch now (0 = all viewers left).
    case viewers(count: Int, change: ViewerChange)
    /// To viewers, once on connect.
    case cameras([CameraPresence])
    /// To viewers, on every change.
    case presence(cameraId: UUID, online: Bool)
    /// To viewers, when a camera's dog state changes.
    case cameraState(cameraId: UUID, state: DogState)
    case error(String)
    /// A message type this app version does not know; ignore it.
    case unknown(type: String)

    public static func decode(_ data: Data) throws -> RealtimeServerMessage {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        switch wire.type {
        case "viewers":
            return .viewers(count: try wire.require(\.count), change: try wire.require(\.change))
        case "cameras":
            return .cameras(try wire.require(\.cameras))
        case "presence":
            return .presence(cameraId: try wire.require(\.cameraId), online: try wire.require(\.online))
        case "cameraState":
            guard let state = DogState(rawValue: try wire.require(\.state)) else { return .unknown(type: wire.type) }
            return .cameraState(cameraId: try wire.require(\.cameraId), state: state)
        case "error":
            return .error(try wire.require(\.error))
        default:
            return .unknown(type: wire.type)
        }
    }

    private struct Wire: Decodable {
        let type: String
        let count: Int?
        let change: ViewerChange?
        let cameras: [CameraPresence]?
        let cameraId: UUID?
        let online: Bool?
        let state: String?
        let error: String?

        func require<T>(_ keyPath: KeyPath<Wire, T?>) throws -> T {
            guard let value = self[keyPath: keyPath] else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Missing field in \(type) message"))
            }
            return value
        }
    }
}

public enum RealtimeClientMessage: Sendable, Equatable {
    /// From cameras, every 30–60 s and when the dog's state changes. `liveKeyMissing`: the
    /// household's live video is end-to-end encrypted and this camera has no key, so it can't
    /// publish (viewers are told right away instead of waiting).
    case heartbeat(CameraHealth, dogState: DogState? = nil, liveKeyMissing: Bool = false)
    /// From viewers.
    case watch(cameraId: UUID)
    case unwatch(cameraId: UUID)

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        switch self {
        case .heartbeat(let health, let dogState, let liveKeyMissing):
            return try encoder.encode(Heartbeat(
                type: "heartbeat",
                battery: health.batteryLevel,
                charging: health.isCharging,
                thermal: health.thermalState.rawValue,
                state: dogState?.rawValue,
                liveKeyMissing: liveKeyMissing ? true : nil
            ))
        case .watch(let cameraId):
            return try encoder.encode(Watch(type: "watch", cameraId: cameraId.uuidString.lowercased()))
        case .unwatch(let cameraId):
            return try encoder.encode(Watch(type: "unwatch", cameraId: cameraId.uuidString.lowercased()))
        }
    }

    private struct Heartbeat: Encodable {
        let type: String
        let battery: Double?
        let charging: Bool
        let thermal: String
        let state: String?
        /// Only sent when true, so older servers see the same message as before.
        let liveKeyMissing: Bool?
    }

    private struct Watch: Encodable {
        let type: String
        let cameraId: String
    }
}
