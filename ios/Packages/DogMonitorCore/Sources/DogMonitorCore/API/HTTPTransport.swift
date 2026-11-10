import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A plain, `Sendable` HTTP response.
public struct HTTPResponse: Sendable, Equatable {
    public var statusCode: Int
    public var body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// Sends a request and returns the raw response. Abstracted so tests can plug in a stub.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// `URLSession`-backed transport. Uses the completion-handler API so it also works with
/// swift-corelibs-foundation on Linux.
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, any Error>) in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: APIError.transport(error.localizedDescription))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: APIError.invalidResponse)
                    return
                }
                continuation.resume(returning: HTTPResponse(statusCode: http.statusCode, body: data ?? Data()))
            }
            task.resume()
        }
    }
}
