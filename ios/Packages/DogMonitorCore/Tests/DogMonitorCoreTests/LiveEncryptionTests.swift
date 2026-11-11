import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import DogMonitorCore

private struct CountingGenerator: RandomNumberGenerator {
    var value: UInt64 = 0x0102_0304_0506_0708
    mutating func next() -> UInt64 {
        value &+= 0x1111_1111_1111_1111
        return value
    }
}

final class LiveKeyTests: XCTestCase {
    func testGeneratedKeysAreThirtyTwoRandomBytes() {
        let a = LiveKey.generate()
        let b = LiveKey.generate()
        XCTAssertEqual(a.data.count, 32)
        XCTAssertNotEqual(a, b)
    }

    func testEncodingRoundTripsAsUnpaddedBase64URL() throws {
        var generator = CountingGenerator()
        let key = LiveKey.generate(using: &generator)
        let encoded = key.encoded
        XCTAssertEqual(encoded.count, LiveKey.encodedLength)
        XCTAssertFalse(encoded.contains("="))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertEqual(LiveKey(encoded: encoded), key)
        XCTAssertEqual(key.passphrase, encoded)

        let allOnes = try XCTUnwrap(LiveKey(data: Data(repeating: 0xFF, count: 32)))
        XCTAssertEqual(allOnes.encoded, String(repeating: "_", count: 42) + "8")
        XCTAssertEqual(LiveKey(encoded: allOnes.encoded), allOnes)
    }

    func testRejectsAnythingElse() {
        XCTAssertNil(LiveKey(data: Data(count: 16)))
        XCTAssertNil(LiveKey(encoded: ""))
        XCTAssertNil(LiveKey(encoded: String(repeating: "A", count: 42)))
        XCTAssertNil(LiveKey(encoded: String(repeating: "A", count: 43) + "="))
        XCTAssertNil(LiveKey(encoded: String(repeating: "A", count: 42) + "+"))
        XCTAssertNil(LiveKey(encoded: String(repeating: "A", count: 42) + "é"))
    }

    func testNeverPrintsTheKey() {
        let key = LiveKey.generate()
        XCTAssertFalse(String(describing: key).contains(key.encoded))
        XCTAssertFalse(String(reflecting: key).contains(key.encoded))
        XCTAssertFalse("\(key)".contains(key.encoded))
    }

    func testStoreKeepsOneKey() throws {
        let store = LiveKeyStore(store: InMemorySecureStore())
        XCTAssertNil(store.load())
        let key = LiveKey.generate()
        try store.save(key)
        XCTAssertEqual(store.load(), key)
        let replacement = LiveKey.generate()
        try store.save(replacement)
        XCTAssertEqual(store.load(), replacement)
        try store.clear()
        XCTAssertNil(store.load())
    }

    func testStoreIgnoresGarbage() throws {
        let secure = InMemorySecureStore()
        try secure.setData(Data("not a key".utf8), forKey: LiveKeyStore.storageKey)
        XCTAssertNil(LiveKeyStore(store: secure).load())
    }
}

final class LiveKeyPairingTests: XCTestCase {
    private let token = "AbCdEfGhIjKlMnOpQrStUvWxYz012-_9"

    func testQRCarriesTheKeyNextToTheToken() throws {
        let key = LiveKey.generate()
        let content = PairingCode.qrContent(token: token, liveKey: key)
        XCTAssertEqual(content, "dogmonitor://pair?t=\(token)&k=\(key.encoded)")
        XCTAssertEqual(PairingCode.parse(content), token, "only the token is sent to the server")
        XCTAssertEqual(PairingCode.liveKey(in: content), key)
        XCTAssertNil(PairingCode.liveKey(in: PairingCode.qrContent(token: token)))
    }

    func testInviteLinkCarriesTheKeyInTheFragment() throws {
        let key = LiveKey.generate()
        let link = try XCTUnwrap(PairingCode.inviteLink(token: token, baseURL: URL(string: "https://api.dogmonitor.app")!, liveKey: key))
        XCTAssertEqual(link.absoluteString, "https://api.dogmonitor.app/invite/\(token)#k=\(key.encoded)")
        XCTAssertNil(link.query, "the key must not be in anything a server receives")
        XCTAssertEqual(PairingCode.parse(link.absoluteString), token)
        XCTAssertEqual(PairingCode.liveKey(in: link.absoluteString), key)
        XCTAssertEqual(PairingCode.liveKey(in: "https://api.dogmonitor.app/invite/\(token)#x=1&k=\(key.encoded)"), key)
    }

    func testTypedCodesAndBrokenKeysCarryNoKey() {
        XCTAssertNil(PairingCode.liveKey(in: "123456"))
        XCTAssertNil(PairingCode.liveKey(in: token))
        XCTAssertNil(PairingCode.liveKey(in: "dogmonitor://pair?t=\(token)&k=short"))
        XCTAssertNil(PairingCode.liveKey(in: "https://api.dogmonitor.app/invite/\(token)#k="))
    }
}

final class LiveEncryptionPolicyTests: XCTestCase {
    func testModes() {
        let key = LiveKey.generate()
        XCTAssertEqual(LiveEncryption.mode(key: key, householdEncrypted: true), .encrypted(key))
        XCTAssertEqual(LiveEncryption.mode(key: key, householdEncrypted: false), .encrypted(key), "a phone with the key always encrypts")
        XCTAssertEqual(LiveEncryption.mode(key: nil, householdEncrypted: true), .needsKey)
        XCTAssertEqual(LiveEncryption.mode(key: nil, householdEncrypted: false), .clear)
    }

    func testTrackDecisions() {
        func decide(_ encrypted: Bool, key: Bool, household: Bool, pinned: Bool) -> LiveEncryption.TrackDecision {
            LiveEncryption.decision(trackEncrypted: encrypted, hasKey: key, householdEncrypted: household, cameraPinned: pinned)
        }
        XCTAssertEqual(decide(true, key: true, household: true, pinned: false), .show)
        XCTAssertEqual(decide(true, key: false, household: false, pinned: false), .needsKey)
        XCTAssertEqual(decide(false, key: true, household: false, pinned: false), .show, "older camera in a household not encrypted yet")
        XCTAssertEqual(decide(false, key: true, household: true, pinned: false), .refuse)
        XCTAssertEqual(decide(false, key: true, household: false, pinned: true), .refuse, "the server can't switch a pinned camera back to clear")
        XCTAssertEqual(decide(false, key: false, household: false, pinned: false), .show)
    }

    func testOwnerActions() {
        XCTAssertEqual(LiveEncryption.ownerAction(hasKey: false, householdEncrypted: false), .createKey)
        XCTAssertEqual(LiveEncryption.ownerAction(hasKey: true, householdEncrypted: false), .markEncrypted)
        XCTAssertEqual(LiveEncryption.ownerAction(hasKey: true, householdEncrypted: true), LiveEncryption.OwnerAction.none)
        XCTAssertEqual(LiveEncryption.ownerAction(hasKey: false, householdEncrypted: true), .replaceLostKey)
    }

    func testPinsPersist() throws {
        let suite = "EncryptedCameraPinsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let camera = UUID()
        let pins = EncryptedCameraPins(defaults: defaults)
        XCTAssertFalse(pins.isPinned(camera))
        pins.pin(camera)
        pins.pin(camera)
        XCTAssertTrue(EncryptedCameraPins(defaults: defaults).isPinned(camera))
        XCTAssertFalse(pins.isPinned(UUID()))
    }
}

final class LiveEncryptionAPITests: XCTestCase {
    func testLiveTokenSaysWhetherTheHouseholdIsEncrypted() async throws {
        let api = { (json: String) in
            DogMonitorAPI(baseURL: URL(string: "https://api.example.com")!, credential: .user(token: "jwt"), transport: StubTransport(json: json))
        }
        let base = #""url":"wss://x.livekit.cloud","token":"t","room":"camera-1","identity":"viewer:u:1","expiresAt":"2026-01-01T00:10:00.000Z""#
        let cameraId = UUID()
        let encrypted = try await api("{\(base),\"encrypted\":true}").liveToken(cameraId: cameraId)
        let clear = try await api("{\(base),\"encrypted\":false}").liveToken(cameraId: cameraId)
        let older = try await api("{\(base)}").liveToken(cameraId: cameraId)
        XCTAssertTrue(encrypted.isHouseholdEncrypted)
        XCTAssertFalse(clear.isHouseholdEncrypted)
        XCTAssertFalse(older.isHouseholdEncrypted, "older servers")
    }

    func testMarkingSendsOnlyTheFlag() async throws {
        let stub = StubTransport(json: #"{"id":"\#(Fixtures.householdID)","name":"Home","plan":"free","liveEncrypted":true}"#)
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .user(token: "t"), transport: stub)
        try await api.markLiveEncrypted()
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/v1/household")
        let body = try Fixtures.bodyJSON(request)
        XCTAssertEqual(Array(body.keys), ["liveEncrypted"])
        XCTAssertEqual(body["liveEncrypted"] as? Bool, true)
    }
}
