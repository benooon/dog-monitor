import Foundation

/// The household's key for end-to-end encrypted live video (SPEC §8).
///
/// The owner's phone makes it once. It travels only from phone to phone: inside the invite
/// QR code (scanned locally) and the fragment of invite links (`#k=…`, which browsers and the
/// app never send to the server). Every camera and viewer of the household hands the same key
/// to LiveKit's shared-key frame encryption, so the media server only relays ciphertext.
///
/// Each key made by this version also has a random `id`, made separately from the key so it
/// says nothing about it. The id travels with the key and is told to the server, so phones and
/// cameras can notice that the owner replaced the key (after removing someone) and ask for a scan.
public struct LiveKey: Sendable, Hashable {
    public static let byteCount = 32
    /// Length of `encoded`: 32 bytes in unpadded base64url.
    public static let encodedLength = 43
    /// Random bytes behind a new key's `id` (12 characters of base64url).
    static let idByteCount = 9

    public let data: Data
    /// Names this key; nil for keys made before ids existed.
    public let id: String?

    public init?(data: Data, id: String? = nil) {
        guard data.count == Self.byteCount else { return nil }
        if let id, !Self.isValidID(id) { return nil }
        self.data = data
        self.id = id
    }

    /// What the server accepts as a key id: 8–64 characters of base64url.
    public static func isValidID(_ id: String) -> Bool {
        (8...64).contains(id.count)
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Whether this is the household's current key. A household without a key id (keys made
    /// before ids existed) never makes a key look replaced.
    public func isCurrent(householdKeyId: String?) -> Bool {
        guard let householdKeyId else { return true }
        return id == householdKeyId
    }

    /// A new random key from the system's cryptographically secure generator.
    public static func generate() -> LiveKey {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }

    /// Tests only pass a seeded generator; the app always uses `generate()`.
    static func generate<G: RandomNumberGenerator>(using generator: inout G) -> LiveKey {
        let key = randomBytes(byteCount, using: &generator)
        let id = base64URL(randomBytes(idByteCount, using: &generator))
        return LiveKey(data: key, id: id)!
    }

    private static func randomBytes<G: RandomNumberGenerator>(_ count: Int, using generator: inout G) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(count + 8)
        while bytes.count < count {
            withUnsafeBytes(of: generator.next()) { bytes.append(contentsOf: $0) }
        }
        return Data(bytes.prefix(count))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The key alone in unpadded base64url, for QR codes, links and the keychain.
    public var encoded: String { Self.base64URL(data) }

    /// Reads `encoded` back, with the key's id if it has one; nil for anything else (wrong
    /// length, padding, other characters, an invalid id).
    public init?(encoded text: String, id: String? = nil) {
        guard text.count == Self.encodedLength,
              text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        let base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        guard let data = Data(base64Encoded: base64) else { return nil }
        self.init(data: data, id: id)
    }

    /// The shared passphrase for LiveKit's key provider (it derives the AES key from it).
    public var passphrase: String { encoded }
}

extension LiveKey: CustomStringConvertible, CustomDebugStringConvertible {
    /// Never print the key itself, so it can't end up in logs.
    public var description: String { "LiveKey(redacted)" }
    public var debugDescription: String { description }
}

/// Keeps this phone's copy of the household's live key in the keychain.
///
/// One slot per phone: a phone belongs to one household (as a viewer, a camera, or both).
public struct LiveKeyStore: Sendable {
    static let storageKey = "liveVideoKey"

    private let store: any SecureStore

    public init(store: any SecureStore) {
        self.store = store
    }

    /// Stored as `<key>` or `<key>.<id>` (`.` is not in base64url).
    public func load() -> LiveKey? {
        guard let data = try? store.data(forKey: Self.storageKey),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        return LiveKey(encoded: String(parts[0]), id: parts.count == 2 ? String(parts[1]) : nil)
    }

    public func save(_ key: LiveKey) throws {
        let text = key.id.map { "\(key.encoded).\($0)" } ?? key.encoded
        try store.setData(Data(text.utf8), forKey: Self.storageKey)
    }

    /// When the phone leaves the household or is unpaired.
    public func clear() throws {
        try store.setData(nil, forKey: Self.storageKey)
    }
}
