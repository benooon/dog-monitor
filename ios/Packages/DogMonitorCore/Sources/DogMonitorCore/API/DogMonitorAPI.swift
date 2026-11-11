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
        try await createDog(DogInput(name: name, photoKey: photoKey))
    }

    /// Creates a dog; `input.name` is required by the server.
    public func createDog(_ input: DogInput) async throws -> DogDTO {
        try await send("POST", "dogs", body: input)
    }

    /// Stores the dog's photo (a JPEG of up to 512 KB; resize on the phone first).
    public func uploadDogPhoto(id: UUID, jpeg: Data) async throws -> DogDTO {
        var request = makeRequest("PUT", "dogs/\(Self.path(id))/photo", body: nil)
        request.httpBody = jpeg
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        return try decode(try await perform(request))
    }

    /// The dog's photo as JPEG data. Fails with 404 when there is none.
    public func dogPhoto(id: UUID) async throws -> Data {
        var request = makeRequest("GET", "dogs/\(Self.path(id))/photo", body: nil)
        request.setValue("image/jpeg", forHTTPHeaderField: "Accept")
        return try await perform(request)
    }

    public func deleteDogPhoto(id: UUID) async throws -> DogDTO {
        try await send("DELETE", "dogs/\(Self.path(id))/photo")
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

    /// Owner only: keep clips members mark right or wrong (90 days) so detection can be trained.
    public func setShareTrainingData(_ enabled: Bool) async throws {
        struct Body: Encodable { let shareTrainingData: Bool }
        struct Response: Decodable { let shareTrainingData: Bool }
        let _: Response = try await send("PATCH", "household", body: Body(shareTrainingData: enabled))
    }

    /// Owner only: a one-hour token for `scripts/export-training-data.mjs`.
    public func trainingExportToken() async throws -> String {
        struct Response: Decodable { let token: String }
        let response: Response = try await send("POST", "training/export-token")
        return response.token
    }

    /// Owner only: removes a member and revokes their phones. 400 `cannot_remove_owner`.
    public func removeMember(userId: UUID) async throws {
        try await sendWithoutResponse("DELETE", "household/members/\(Self.path(userId))")
    }

    /// Permanently deletes the signed-in account. An owner living alone also loses the household, its
    /// events and stored files. 409 `household_has_members` while an owner still has other members.
    public func deleteAccount() async throws {
        try await sendWithoutResponse("DELETE", "me")
    }

    /// Everything the server holds about the signed-in user, as JSON (no clips or snapshots).
    public func exportMyData() async throws -> Data {
        try await perform(makeRequest("GET", "me/export", body: nil))
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

    /// The household and inviter behind an invite, without using it up. Needs no credential.
    public func invitePreview(_ tokenOrCode: String) async throws -> InvitePreviewDTO {
        try await send("GET", "invites/\(tokenOrCode)/preview")
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

    // MARK: - Timeline (user auth)

    /// A page of the household's events, newest first. 400 `invalid_cursor` for a stale cursor.
    public func timeline(_ filter: TimelineFilter = .all, cursor: String? = nil, limit: Int? = nil) async throws -> TimelinePage {
        var components = URLComponents()
        let items = filter.queryItems(cursor: cursor, limit: limit)
        components.queryItems = items.isEmpty ? nil : items
        return try await send("GET", "events" + (components.percentEncodedQuery.map { "?" + $0 } ?? ""))
    }

    /// Marks a detection right or wrong (`nil` clears it); returns the updated event.
    public func setFeedback(eventId: UUID, _ feedback: DogEvent.Feedback?) async throws -> EventDTO {
        try await send("PUT", "events/\(Self.path(eventId))/feedback", body: EventFeedbackRequest(feedback: feedback))
    }

    /// Download URLs for an event's clip and snapshot. 503 `storage_not_configured` without a bucket.
    public func eventMedia(eventId: UUID) async throws -> EventMediaDTO {
        try await send("GET", "events/\(Self.path(eventId))/media")
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

    // MARK: - Zones (camera device auth)

    public func zones() async throws -> [CameraZone] {
        let response: CameraZonesDTO = try await send("GET", "device/zones")
        return response.zones
    }

    /// Replaces all of this camera's zones; returns what is now stored.
    public func replaceZones(_ zones: [CameraZone]) async throws -> [CameraZone] {
        let response: CameraZonesDTO = try await send("PUT", "device/zones", body: CameraZonesDTO(zones: zones))
        return response.zones
    }

    // MARK: - Daily summaries

    /// Camera: uploads its day so far; `final` once the day is over (sends the summary push once).
    public func uploadSummary(_ summary: DailySummary, final: Bool) async throws {
        let body = DailySummaryUpload(
            restMinutes: summary.restMinutes,
            barkCount: summary.barkCount,
            activityByHour: summary.activityByHour,
            stateMinutes: summary.stateMinutes,
            final: final
        )
        let _: DailySummaryDTO = try await send("PUT", "device/summaries/\(summary.date)", body: body)
    }

    /// Viewer: stored days, newest first (`from` / `to` are "YYYY-MM-DD").
    public func summaries(cameraId: UUID? = nil, from: String? = nil, to: String? = nil) async throws -> [DailySummaryDTO] {
        var items: [URLQueryItem] = []
        if let cameraId { items.append(URLQueryItem(name: "cameraId", value: Self.path(cameraId))) }
        if let from { items.append(URLQueryItem(name: "from", value: from)) }
        if let to { items.append(URLQueryItem(name: "to", value: to)) }
        var components = URLComponents()
        components.queryItems = items.isEmpty ? nil : items
        let list: DailySummaryList = try await send("GET", "summaries" + (components.percentEncodedQuery.map { "?" + $0 } ?? ""))
        return list.summaries
    }

    // MARK: - Highlight reels

    /// Camera: a presigned PUT for the day's reel. 404 `summary_not_found` before that day's
    /// summary is uploaded, 403 `premium_required` on the free plan, 503 without a bucket.
    public func requestReelUpload(date: String) async throws -> PresignedUploadDTO {
        let response: ReelUploadDTO = try await send("POST", "device/reels/\(date)/upload")
        return response.upload
    }

    /// Camera: the reel is uploaded; attach it to that day's summary.
    public func attachReel(date: String) async throws {
        let _: ReelAttachedDTO = try await send("PUT", "device/reels/\(date)")
    }

    /// Viewer: a download URL for a camera's reel of `date`. 404 when there is none.
    public func reel(cameraId: UUID, date: String) async throws -> ReelMediaDTO {
        try await send("GET", "summaries/\(Self.path(cameraId))/\(date)/reel")
    }

    // MARK: - Notification preferences (user auth)

    /// The caller's push preferences and the defaults for types without a preference.
    public func notificationPrefs() async throws -> NotificationPrefsDTO {
        try await send("GET", "notification-prefs")
    }

    /// Replaces all of the caller's preference rows; returns what is now stored.
    public func replaceNotificationPrefs(_ prefs: [NotificationPrefDTO]) async throws -> NotificationPrefsDTO {
        try await send("PUT", "notification-prefs", body: NotificationPrefsRequest(prefs: prefs))
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

    // MARK: - Subscription

    /// The household's plan, camera limit and usage.
    public func subscription() async throws -> SubscriptionDTO {
        try await send("GET", "subscription")
    }

    /// Owner only: reports a StoreKit 2 signed transaction (`jwsRepresentation`).
    /// 400 when it can't be verified, 409 `subscription_in_use` when it unlocks another household,
    /// 503 `purchases_not_configured`.
    public func reportAppleTransaction(_ signedTransaction: String) async throws -> SubscriptionDTO {
        struct Body: Encodable { let signedTransaction: String }
        return try await send("POST", "subscription/apple", body: Body(signedTransaction: signedTransaction))
    }

    // MARK: - Live Activities (user auth)

    /// Registers the ActivityKit push token of a Live Activity showing `cameraId`, so the backend
    /// can update it. Call again whenever `pushTokenUpdates` yields a new token.
    /// 404 `camera_not_found` when the camera isn't an active camera in this household.
    public func registerLiveActivity(cameraId: UUID, pushToken: Data) async throws -> LiveActivityRegistrationDTO {
        let body = LiveActivityRegistrationRequest(cameraId: Self.path(cameraId), pushToken: PushToken.hex(pushToken))
        return try await send("PUT", "live-activities", body: body)
    }

    /// Forgets a Live Activity once it has ended. 404 when it is already gone.
    public func endLiveActivity(id: UUID) async throws {
        try await sendWithoutResponse("DELETE", "live-activities/\(Self.path(id))")
    }

    // MARK: - Plumbing

    static func path(_ id: UUID) -> String { id.uuidString.lowercased() }

    func makeRequest(_ method: String, _ path: String, body: Data?) -> URLRequest {
        // A "?query" suffix is kept as the query instead of being escaped into the path.
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var url = baseURL.appendingPathComponent(String(parts[0]))
        if parts.count == 2, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = String(parts[1])
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
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
