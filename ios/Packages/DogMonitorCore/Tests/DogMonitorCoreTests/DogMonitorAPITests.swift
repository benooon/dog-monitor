import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import DogMonitorCore

final class DogMonitorAPITests: XCTestCase {
    func testSignInWithApplePostsJSONAndDecodes() async throws {
        let stub = StubTransport(json: #"{"token":"jwt-1","user":{"id":"\#(Fixtures.userID)","name":"Ben"}}"#)
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, transport: stub)

        let auth = try await api.signInWithApple(identityToken: "apple-token", nonce: "raw-nonce", name: "Ben")

        XCTAssertEqual(auth.token, "jwt-1")
        XCTAssertEqual(auth.user.id, UUID(uuidString: Fixtures.userID))
        XCTAssertEqual(auth.user.name, "Ben")

        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/auth/apple")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try Fixtures.bodyJSON(request)
        XCTAssertEqual(body["identityToken"] as? String, "apple-token")
        XCTAssertEqual(body["name"] as? String, "Ben")
        XCTAssertEqual(body["nonce"] as? String, "raw-nonce")
    }

    func testOmitsNilFieldsInRequests() async throws {
        let stub = StubTransport(json: #"{"token":"t","user":{"id":"\#(Fixtures.userID)","name":null}}"#)
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, transport: stub)
        _ = try await api.signInWithApple(identityToken: "x", nonce: "n")
        let body = try Fixtures.bodyJSON(try XCTUnwrap(stub.requests.first))
        XCTAssertNil(body["name"], "nil must be omitted, the backend rejects null names")
    }

    func testUserAndDeviceAuthorizationHeaders() async throws {
        let stub = StubTransport(json: Fixtures.deviceJSON)
        let base = DogMonitorAPI(baseURL: Fixtures.baseURL, transport: stub)

        _ = try await base.with(credential: .user(token: "jwt-1")).currentDevice()
        let deviceID = try XCTUnwrap(UUID(uuidString: Fixtures.deviceID))
        _ = try await base.with(credential: .device(id: deviceID, secret: "s3cret")).currentDevice()

        XCTAssertEqual(stub.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer jwt-1")
        XCTAssertEqual(stub.requests[1].value(forHTTPHeaderField: "Authorization"), "Device \(Fixtures.deviceID):s3cret")
        XCTAssertEqual(stub.requests[1].url?.path, "/v1/device/me")
    }

    func testDecodesDatesWithAndWithoutFractionalSeconds() async throws {
        let json = """
        [{"id":"\(Fixtures.userID)","householdId":"\(Fixtures.householdID)","name":"Rex","photoKey":null,
          "createdAt":"2026-11-10T07:00:00.250Z"},
         {"id":"\(Fixtures.deviceID)","householdId":"\(Fixtures.householdID)","name":"Bella","photoKey":"dogs/b.jpg",
          "createdAt":"2026-11-10T07:00:00Z"}]
        """
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .user(token: "t"), transport: StubTransport(json: json))
        let dogs = try await api.dogs()
        XCTAssertEqual(dogs.map(\.name), ["Rex", "Bella"])
        XCTAssertEqual(dogs[0].createdAt.timeIntervalSince1970, 1_794_294_000.25, accuracy: 0.001)
        XCTAssertEqual(dogs[1].createdAt.timeIntervalSince1970, 1_794_294_000, accuracy: 0.001)
        XCTAssertEqual(dogs[1].photoKey, "dogs/b.jpg")
    }

    func testMapsHTTPErrorsToAPIError() async {
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, transport: StubTransport(status: 401, json: #"{"error":"unauthorized"}"#))
        do {
            _ = try await api.me()
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error, .http(status: 401, code: "unauthorized"))
            XCTAssertTrue(error.isUnauthorized)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testHTTPErrorWithoutJSONBody() async {
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, transport: StubTransport(status: 502, json: "Bad Gateway"))
        do {
            _ = try await api.health()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? APIError, .http(status: 502, code: nil))
        }
    }

    func testDecodingErrors() async {
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, transport: StubTransport(json: #"{"unexpected":true}"#))
        do {
            _ = try await api.health()
            XCTFail("expected an error")
        } catch let error as APIError {
            guard case .decoding = error else { return XCTFail("expected .decoding, got \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testDeleteAcceptsEmptyNoContent() async throws {
        let stub = StubTransport(status: 204, json: "")
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .user(token: "t"), transport: stub)
        let id = UUID()
        try await api.deleteDog(id: id)
        XCTAssertEqual(stub.requests.first?.httpMethod, "DELETE")
        XCTAssertEqual(stub.requests.first?.url?.lastPathComponent, id.uuidString.lowercased())
    }

    func testPairingAsCamera() async throws {
        let json = #"{"householdId":"\#(Fixtures.householdID)","device":\#(Fixtures.deviceJSON),"deviceSecret":"secret-1"}"#
        let stub = StubTransport(json: json)
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, transport: stub)

        let pairing = try await api.acceptInviteAsCamera("123456", deviceName: "Living room", model: "iPhone12,1")

        XCTAssertEqual(pairing.deviceSecret, "secret-1")
        XCTAssertEqual(pairing.device.role, .camera)
        XCTAssertEqual(pairing.device.status, .active)
        XCTAssertNil(pairing.device.userId)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/invites/123456/accept")
        let body = try Fixtures.bodyJSON(request)
        XCTAssertEqual(body["as"] as? String, "camera")
        XCTAssertEqual(body["deviceName"] as? String, "Living room")
        XCTAssertNil(body["appVersion"])
    }

    func testJoiningAsMember() async throws {
        let stub = StubTransport(json: #"{"householdId":"\#(Fixtures.householdID)","role":"member"}"#)
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .user(token: "t"), transport: stub)
        let joined = try await api.acceptInviteAsMember("tok_abc-123")
        XCTAssertEqual(joined.role, .member)
        let body = try Fixtures.bodyJSON(try XCTUnwrap(stub.requests.first))
        XCTAssertEqual(body.count, 1)
        XCTAssertEqual(body["as"] as? String, "member")
    }

    func testHouseholdDecoding() async throws {
        let json = """
        {"id":"\(Fixtures.householdID)","name":"Home","plan":"free","ownerId":"\(Fixtures.userID)","role":"owner",
         "members":[{"userId":"\(Fixtures.userID)","name":"Ben","role":"owner"}],
         "dogs":[],"devices":[\(Fixtures.deviceJSON)]}
        """
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .user(token: "t"), transport: StubTransport(json: json))
        let household = try await api.household()
        XCTAssertEqual(household.role, .owner)
        XCTAssertEqual(household.members.first?.name, "Ben")
        XCTAssertEqual(household.devices.first?.name, "Living room")
    }

    func testHouseholdKnowsAboutForbiddenZones() async throws {
        let withSofa = Fixtures.deviceJSON.replacingOccurrences(
            of: #""thermal":null,"#, with: #""thermal":null,"zoneKinds":["door","forbidden","garden"],"#
        )
        let json = """
        {"id":"\(Fixtures.householdID)","name":"Home","plan":"free","ownerId":"\(Fixtures.userID)","role":"owner",
         "members":[],"dogs":[],"devices":[\(withSofa)]}
        """
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .user(token: "t"), transport: StubTransport(json: json))
        let household = try await api.household()
        XCTAssertEqual(household.devices.first?.zones, [.door, .forbidden], "unknown kinds are ignored")
        XCTAssertTrue(household.hasForbiddenZone)

        let olderAPI = DogMonitorAPI(
            baseURL: Fixtures.baseURL, credential: .user(token: "t"),
            transport: StubTransport(json: json.replacingOccurrences(of: withSofa, with: Fixtures.deviceJSON))
        )
        let older = try await olderAPI.household()
        XCTAssertEqual(older.devices.first?.zones, [])
        XCTAssertFalse(older.hasForbiddenZone)

        let sofaOnlyAPI = DogMonitorAPI(
            baseURL: Fixtures.baseURL, credential: .user(token: "t"),
            transport: StubTransport(json: json.replacingOccurrences(of: #"["door","forbidden","garden"]"#, with: #"["sofa"]"#))
        )
        let sofaOnly = try await sofaOnlyAPI.household()
        XCTAssertEqual(sofaOnly.devices.first?.zones, [.sofa])
        XCTAssertTrue(sofaOnly.hasForbiddenZone)
    }

    func testUpdateDeviceSendsOnlyChangedFields() async throws {
        let stub = StubTransport(json: Fixtures.deviceJSON)
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .user(token: "t"), transport: stub)
        _ = try await api.updateDevice(id: UUID(), UpdateDeviceRequest(apnsToken: "abcdef0123456789abcdef0123456789"))
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.httpMethod, "PATCH")
        let body = try Fixtures.bodyJSON(request)
        XCTAssertEqual(Array(body.keys), ["apnsToken"])
    }
}

/// Exercises the real URLSession path through a URLProtocol stub.
final class URLSessionTransportTests: XCTestCase {
    func testRoundTripThroughURLSession() async throws {
        StubURLProtocol.reply = .init(status: 200, body: Data(#"{"status":"ok","uptimeSeconds":12,"version":"0.1.0"}"#.utf8))
        let api = DogMonitorAPI(
            baseURL: Fixtures.baseURL,
            credential: .user(token: "jwt-9"),
            transport: URLSessionTransport(session: StubURLProtocol.makeSession())
        )

        let health = try await api.health()

        XCTAssertEqual(health, HealthResponse(status: "ok", uptimeSeconds: 12, version: "0.1.0"))
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.absoluteString, "https://api.example.com/v1/health")
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-9")
    }

    func testErrorStatusThroughURLSession() async {
        StubURLProtocol.reply = .init(status: 404, body: Data(#"{"error":"not_found"}"#.utf8))
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, transport: URLSessionTransport(session: StubURLProtocol.makeSession()))
        do {
            _ = try await api.dogs()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? APIError, .http(status: 404, code: "not_found"))
        }
    }
}

final class DeviceStatusTests: XCTestCase {
    private func device(status: String = "active", role: String = "camera", heartbeat: String?) throws -> DeviceDTO {
        let hb = heartbeat.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"id":"\(UUID())","householdId":"\(UUID())","userId":null,"name":"Cam","role":"\(role)","model":null,
         "appVersion":null,"hasPushToken":false,"status":"\(status)","lastHeartbeatAt":\(hb),"battery":null,
         "charging":null,"thermal":null,"createdAt":"2026-11-10T07:00:00Z"}
        """
        return try JSONCoding.makeDecoder().decode(DeviceDTO.self, from: Data(json.utf8))
    }

    func testOnlineWithinThreeMinutesOfHeartbeat() throws {
        let now = try XCTUnwrap(JSONCoding.parseISO8601("2026-11-10T08:00:00Z"))
        XCTAssertTrue(try device(heartbeat: "2026-11-10T07:58:00.000Z").isOnline(now: now))
        XCTAssertFalse(try device(heartbeat: "2026-11-10T07:56:59Z").isOnline(now: now))
        XCTAssertFalse(try device(heartbeat: nil).isOnline(now: now))
        XCTAssertFalse(try device(status: "revoked", heartbeat: "2026-11-10T07:59:00Z").isOnline(now: now))
    }
}
