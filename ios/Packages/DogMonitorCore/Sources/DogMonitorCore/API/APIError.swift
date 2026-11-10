import Foundation

public enum APIError: Error, Equatable, Sendable {
    /// The server answered with a non-2xx status. `code` is the `error` field of the JSON body, if any.
    case http(status: Int, code: String?)
    /// The response body did not match the expected shape.
    case decoding(String)
    /// Network-level failure (offline, timeout, TLS...).
    case transport(String)
    /// The response was not HTTP.
    case invalidResponse

    public var isUnauthorized: Bool {
        if case .http(401, _) = self { return true }
        return false
    }
}

struct ErrorBody: Decodable {
    let error: String
}
