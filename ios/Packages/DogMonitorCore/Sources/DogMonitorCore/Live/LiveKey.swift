import Foundation

/// The household's key for end-to-end encrypted live video (SPEC §8).
///
/// The owner's phone makes it once. It travels only from phone to phone: inside the invite
/// QR code (scanned locally) and the fragment of invite links (`#k=…`, which browsers and the
/// app never send to the server). Every camera and viewer of the household hands the same key
/// to LiveKit's shared-key frame encryption, so the media server only relays ciphertext.
public struct LiveKey: Sendable, Hashable {
    public static let byteCount = 32
    /// Length of `encoded`: 32 bytes in unpadded base64url.
    public static let encodedLength = 43

    public let data: Data

    public init?(data: Data) {
        guard data.count == Self.byteCount else { return nil }
        self.data = data
    }

    /// A new random key from the system's cryptographically secure generator.
    public static func generate() -> LiveKey {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }

    /// Tests only pass a seeded generator; the app always uses `generate()`.
    static func generate<G: RandomNumberGenerator>(using generator: inout G) -> LiveKey {
        var bytes = [UInt8]()
        bytes.reserveCapacity(byteCount)
        while bytes.count < byteCount {
            withUnsafeBytes(of: generator.next()) { bytes.append(contentsOf: $0) }
        }
        return LiveKey(data: Data(bytes.prefix(byteCount)))!
    }

    /// Unpadded base64url, for QR codes, links and the keychain.
    public var encoded: String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Reads `encoded` back; nil for anything else (wrong length, padding, other characters).
    public init?(encoded text: String) {
        guard text.count == Self.encodedLength,
              text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        let base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        guard let data = Data(base64Encoded: base64) else { return nil }
        self.init(data: data)
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

    public func load() -> LiveKey? {
        guard let data = try? store.data(forKey: Self.storageKey),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return LiveKey(encoded: text)
    }

    public func save(_ key: LiveKey) throws {
        try store.setData(Data(key.encoded.utf8), forKey: Self.storageKey)
    }

    /// When the phone leaves the household or is unpaired.
    public func clear() throws {
        try store.setData(nil, forKey: Self.storageKey)
    }
}
