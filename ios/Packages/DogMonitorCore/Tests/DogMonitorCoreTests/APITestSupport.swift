import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import DogMonitorCore

/// In-memory transport that records requests and replies with canned responses.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let respond: @Sendable (URLRequest) throws -> HTTPResponse

    init(_ respond: @escaping @Sendable (URLRequest) throws -> HTTPResponse) {
        self.respond = respond
    }

    convenience init(status: Int = 200, json: String) {
        self.init { _ in HTTPResponse(statusCode: status, body: Data(json.utf8)) }
    }

    var requests: [URLRequest] {
        lock.withLock { _requests }
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock { _requests.append(request) }
        return try respond(request)
    }
}

/// URLProtocol stub so the real `URLSessionTransport` can be exercised without a network.
final class StubURLProtocol: URLProtocol {
    struct Reply: Sendable {
        var status: Int
        var body: Data
    }

    nonisolated(unsafe) static var reply = Reply(status: 200, body: Data())
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let reply = Self.reply
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

enum Fixtures {
    static let baseURL = URL(string: "https://api.example.com/v1")!
    static let userID = "5b0a8e1c-3f2d-4c1a-9b7e-0123456789ab"
    static let householdID = "0f9e8d7c-6b5a-4f3e-8d2c-1b0a99887766"
    static let deviceID = "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"

    static let deviceJSON = """
    {"id":"\(deviceID)","householdId":"\(householdID)","userId":null,"name":"Living room",
     "role":"camera","model":"iPhone12,1","appVersion":"0.1.0","hasPushToken":false,"status":"active",
     "lastHeartbeatAt":null,"battery":null,"charging":null,"thermal":null,
     "createdAt":"2026-11-10T07:00:00.123Z"}
    """

    static func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrapData(request.httpBody)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private static func XCTUnwrapData(_ data: Data?) throws -> Data {
        guard let data else { throw APIError.decoding("request has no body") }
        return data
    }
}
