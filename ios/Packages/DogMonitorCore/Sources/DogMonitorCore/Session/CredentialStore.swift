import Foundation

/// Persists the backend credential (user JWT or camera device secret) in a `SecureStore`.
public struct CredentialStore: Sendable {
    static let key = "dogmonitor.credential"

    private let store: any SecureStore

    public init(store: any SecureStore) {
        self.store = store
    }

    public func load() -> APICredential {
        guard let data = try? store.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode(StoredCredential.self, from: data)
        else { return .none }
        return stored.credential
    }

    public func save(_ credential: APICredential) throws {
        if credential == .none {
            try store.setData(nil, forKey: Self.key)
        } else {
            try store.setData(try JSONEncoder().encode(StoredCredential(credential)), forKey: Self.key)
        }
    }

    public func clear() throws {
        try store.setData(nil, forKey: Self.key)
    }
}

private struct StoredCredential: Codable {
    var userToken: String?
    var deviceID: UUID?
    var deviceSecret: String?

    init(_ credential: APICredential) {
        switch credential {
        case .none: break
        case .user(let token): userToken = token
        case .device(let id, let secret):
            deviceID = id
            deviceSecret = secret
        }
    }

    var credential: APICredential {
        if let userToken { return .user(token: userToken) }
        if let deviceID, let deviceSecret { return .device(id: deviceID, secret: deviceSecret) }
        return .none
    }
}
