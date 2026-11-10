import Foundation

/// Key-value storage for secrets. The app implements it with the Keychain; tests use `InMemorySecureStore`.
public protocol SecureStore: Sendable {
    func data(forKey key: String) throws -> Data?
    func setData(_ data: Data?, forKey key: String) throws
}

public final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    public init() {}

    public func data(forKey key: String) throws -> Data? {
        lock.withLock { values[key] }
    }

    public func setData(_ data: Data?, forKey key: String) throws {
        lock.withLock { values[key] = data }
    }
}
