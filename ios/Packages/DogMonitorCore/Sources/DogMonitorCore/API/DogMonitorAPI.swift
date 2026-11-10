import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Typed client for the Dog Monitor backend.
public struct DogMonitorAPI: Sendable {
    public var baseURL: URL
    public var credential: APICredential
    private let transport: any HTTPTransport

    public init(baseURL: URL, credential: APICredential = .none, transport: any HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.credential = credential
        self.transport = transport
    }

    /// A copy of this client that authenticates with `credential`.
    public func with(credential: APICredential) -> DogMonitorAPI {
        var copy = self
        copy.credential = credential
        return copy
    }

    // MARK: - Health & auth

    public func health() async throws -> HealthResponse {
        try await send("GET", "health")
    }

    public func signInWithApple(identityToken: String, nonce: String, name: String? = nil) async throws -> AuthResponse {
        try await send("POST", "auth/apple", body: AppleSignInRequest(identityToken: identityToken, nonce: nonce, name: name))
    }

    public func me() async throws -> MeResponse {
        try await send("GET", "me")
    }

    // MARK: - Household

    public func createHousehold(name: String) async throws -> CreatedHouseholdDTO {
        try await send("POST", "households", body: NameRequest(name: name))
    }

    public func household() async throws -> HouseholdDTO {
        try await send("GET", "household")
    }

    // MARK: - Dogs

    public func dogs() async throws -> [DogDTO] {
        try await send("GET", "dogs")
    }

    public func createDog(name: String, photoKey: String? = nil) async throws -> DogDTO {
        try await send("POST", "dogs", body: DogInput(name: name, photoKey: photoKey))
    }

    public func updateDog(id: UUID, _ changes: DogInput) async throws -> DogDTO {
        try await send("PATCH", "dogs/\(Self.path(id))", body: changes)
    }

    public func deleteDog(id: UUID) async throws {
        try await sendWithoutResponse("DELETE", "dogs/\(Self.path(id))")
    }

    // MARK: - Devices

    public func devices() async throws -> [DeviceDTO] {
        try await send("GET", "devices")
    }

    public func registerDevice(_ request: RegisterDeviceRequest) async throws -> DeviceDTO {
        try await send("POST", "devices", body: request)
    }

    public func updateDevice(id: UUID, _ changes: UpdateDeviceRequest) async throws -> DeviceDTO {
        try await send("PATCH", "devices/\(Self.path(id))", body: changes)
    }

    public func revokeDevice(id: UUID) async throws -> DeviceDTO {
        try await send("POST", "devices/\(Self.path(id))/revoke")
    }

    /// The calling camera device (requires `.device` credentials).
    public func currentDevice() async throws -> DeviceDTO {
        try await send("GET", "device/me")
    }

    // MARK: - Invites & pairing

    public func createInvite() async throws -> InviteDTO {
        try await send("POST", "invites")
    }

    /// Joins the inviting household as a member. `tokenOrCode` is the QR token or the 6-digit code.
    public func acceptInviteAsMember(_ tokenOrCode: String) async throws -> MemberJoinResponse {
        try await send("POST", "invites/\(tokenOrCode)/accept", body: AcceptAsMemberRequest())
    }

    /// Pairs this device as a camera. No user credential is needed.
    public func acceptInviteAsCamera(
        _ tokenOrCode: String,
        deviceName: String,
        model: String? = nil,
        appVersion: String? = nil
    ) async throws -> CameraPairingResponse {
        try await send(
            "POST",
            "invites/\(tokenOrCode)/accept",
            body: AcceptAsCameraRequest(deviceName: deviceName, model: model, appVersion: appVersion)
        )
    }

    /// Latest snapshot per camera. 503 `storage_not_configured` until the backend has a bucket.
    public func cameraSnapshots() async throws -> [CameraSnapshotDTO] {
        try await send("GET", "cameras/snapshots")
    }

    // MARK: - Events (camera device auth)

    public func createEvent(_ request: CreateEventRequest) async throws -> EventDTO {
        try await send("POST", "events", body: request)
    }

    public func updateEvent(id: UUID, _ request: UpdateEventRequest) async throws -> EventDTO {
        try await send("PATCH", "events/\(Self.path(id))", body: request)
    }

    // MARK: - Event media (camera device auth)

    /// Presigned PUT URLs for an event's media. 503 `storage_not_configured` without a bucket.
    public func requestUploads(eventId: UUID, kinds: [MediaKind]) async throws -> MediaUploadsDTO {
        try await send("POST", "device/uploads", body: MediaUploadsRequest(eventId: Self.path(eventId), kinds: kinds))
    }

    /// PUTs `data` to a presigned URL. The URL carries its own authorization, so no credential is sent.
    public func upload(_ data: Data, to target: PresignedUploadDTO) async throws {
        var request = URLRequest(url: target.url)
        request.httpMethod = "PUT"
        request.httpBody = data
        for (field, value) in target.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        _ = try await perform(request)
    }

    // MARK: - Live view & realtime

    /// A viewer token for watching `cameraId` live. Fails with 409 `viewer_limit_reached`,
    /// or 503 `live_not_configured` until the backend has LiveKit credentials.
    public func liveToken(cameraId: UUID) async throws -> LiveTokenDTO {
        try await send("POST", "cameras/\(Self.path(cameraId))/live-token")
    }

    /// A publisher token for this camera's own room (requires `.device` credentials).
    public func deviceLiveToken() async throws -> LiveTokenDTO {
        try await send("POST", "device/live-token")
    }

    /// The upgrade request for the realtime WebSocket (`GET /ws`), authenticated like any call.
    public func realtimeRequest() -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        var request = URLRequest(url: components?.url ?? baseURL)
        if let header = credential.authorizationHeader {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: - Plumbing

    static func path(_ id: UUID) -> String { id.uuidString.lowercased() }

    func makeRequest(_ method: String, _ path: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let header = credential.authorizationHeader {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<Response: Decodable>(_ method: String, _ path: String) async throws -> Response {
        try decode(try await perform(makeRequest(method, path, body: nil)))
    }

    private func send<Response: Decodable>(
        _ method: String,
        _ path: String,
        body: some Encodable
    ) async throws -> Response {
        let data = try JSONCoding.makeEncoder().encode(body)
        return try decode(try await perform(makeRequest(method, path, body: data)))
    }

    private func sendWithoutResponse(_ method: String, _ path: String) async throws {
        _ = try await perform(makeRequest(method, path, body: nil))
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) else {
            let code = try? JSONDecoder().decode(ErrorBody.self, from: response.body).error
            throw APIError.http(status: response.statusCode, code: code)
        }
        return response.body
    }

    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        do {
            return try JSONCoding.makeDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }
}
