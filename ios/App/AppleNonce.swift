import CryptoKit
import Foundation
import Security

/// One-time nonce for Sign in with Apple. Apple gets the SHA-256; the backend gets the raw value.
struct AppleNonce: Equatable {
    let raw: String

    var sha256: String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func random(byteCount: Int = 32) -> AppleNonce {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        if SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) != errSecSuccess {
            // Fall back to the system RNG; both are cryptographically secure.
            var rng = SystemRandomNumberGenerator()
            bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        }
        return AppleNonce(raw: Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: ""))
    }
}
