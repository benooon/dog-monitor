import Foundation

/// How a request authenticates with the backend.
public enum APICredential: Sendable, Equatable {
    case none
    /// A signed-in user's JWT from `POST /auth/apple`.
    case user(token: String)
    /// A paired camera device (`Authorization: Device <id>:<secret>`).
    case device(id: UUID, secret: String)

    var authorizationHeader: String? {
        switch self {
        case .none: nil
        case .user(let token): "Bearer \(token)"
        case .device(let id, let secret): "Device \(id.uuidString.lowercased()):\(secret)"
        }
    }
}
