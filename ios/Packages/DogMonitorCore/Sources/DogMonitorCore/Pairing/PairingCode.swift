import Foundation

/// Encodes invites into QR codes and reads back whatever a user scans or types (SPEC §3 Pairing).
public enum PairingCode {
    public static let scheme = "dogmonitor"

    /// QR content for an invite: `dogmonitor://pair?t=<token>`.
    public static func qrContent(token: String) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "pair"
        components.queryItems = [URLQueryItem(name: "t", value: token)]
        return components.string ?? "\(scheme)://pair?t=\(token)"
    }

    /// The invite token or 6-digit code in scanned or typed text, ready for
    /// `POST /invites/:tokenOrCode/accept`, or nil if it is neither.
    ///
    /// Accepts `dogmonitor://pair?t=…`, any https link with a `/pair` path and `t` (future
    /// Universal Links), a bare token, or a 6-digit code typed with spaces or dashes.
    public static func parse(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter { $0 != " " && $0 != "-" }
        if digits.count == 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return digits
        }
        if let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased() {
            let isAppLink = scheme == Self.scheme && components.host == "pair"
            let isWebLink = scheme == "https" && components.path.hasSuffix("/pair")
            guard isAppLink || isWebLink,
                  let token = components.queryItems?.first(where: { $0.name == "t" })?.value
            else { return nil }
            return isToken(token) ? token : nil
        }
        return isToken(trimmed) ? trimmed : nil
    }

    /// Backend tokens are 24 random bytes in base64url (32 characters).
    static func isToken(_ text: String) -> Bool {
        (16...128).contains(text.count)
            && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// Time left on an invite, for the countdown under the QR code.
public struct InviteCountdown: Sendable, Equatable {
    public let expiresAt: Date

    public init(expiresAt: Date) {
        self.expiresAt = expiresAt
    }

    public func remaining(at now: Date) -> TimeInterval {
        max(expiresAt.timeIntervalSince(now), 0)
    }

    public func isExpired(at now: Date) -> Bool {
        remaining(at: now) == 0
    }

    /// "m:ss" for display (digits only, so it reads the same in RTL).
    public func label(at now: Date) -> String {
        let seconds = Int(remaining(at: now).rounded(.up))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
