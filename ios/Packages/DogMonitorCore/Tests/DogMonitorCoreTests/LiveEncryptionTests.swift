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
        XCTAssertEqual(LiveKey(encoded: encoded, id: key.id), key)
        XCTAssertEqual(LiveKey(encoded: encoded)?.data, key.data)
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

    func testNewKeysHaveTheirOwnRandomID() throws {
        let a = LiveKey.generate()
        let b = LiveKey.generate()
        let id = try XCTUnwrap(a.id)
        XCTAssertEqual(id.count, 12)
        XCTAssertTrue(LiveKey.isValidID(id))
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertFalse(a.encoded.contains(id), "the id is not part of the key")
    }

    func testIDsAreValidated() {
        let data = Data(repeating: 1, count: 32)
        XCTAssertNotNil(LiveKey(data: data, id: "abcDEF-_0123"))
        XCTAssertNil(LiveKey(data: data, id: "short"))
        XCTAssertNil(LiveKey(data: data, id: "has space in"))
        XCTAssertNil(LiveKey(data: data, id: "with.dot.here"))
        XCTAssertNil(LiveKey(data: data, id: String(repeating: "a", count: 65)))
    }

    func testCurrentKey() throws {
        let key = LiveKey.generate()
        let id = try XCTUnwrap(key.id)
        XCTAssertTrue(key.isCurrent(householdKeyId: nil), "households from before ids")
        XCTAssertTrue(key.isCurrent(householdKeyId: id))
        XCTAssertFalse(key.isCurrent(householdKeyId: "another-key-id"))
        let legacy = try XCTUnwrap(LiveKey(encoded: key.encoded))
        XCTAssertTrue(legacy.isCurrent(householdKeyId: nil))
        XCTAssertFalse(legacy.isCurrent(householdKeyId: id))
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

    func testStoreKeepsTheIDAndReadsKeysFromBeforeIDs() throws {
        let secure = InMemorySecureStore()
        let store = LiveKeyStore(store: secure)
        let key = LiveKey.generate()
        try store.save(key)
        XCTAssertEqual(store.load()?.id, key.id)

        try secure.setData(Data(key.encoded.utf8), forKey: LiveKeyStore.storageKey)
        let legacy = try XCTUnwrap(store.load())
        XCTAssertEqual(legacy.data, key.data)
        XCTAssertNil(legacy.id)

        try secure.setData(Data("\(key.encoded).bad id".utf8), forKey: LiveKeyStore.storageKey)
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
        let id = try XCTUnwrap(key.id)
        XCTAssertEqual(content, "dogmonitor://pair?t=\(token)&k=\(key.encoded)&kid=\(id)")
        XCTAssertEqual(PairingCode.parse(content), token, "only the token is sent to the server")
        XCTAssertEqual(PairingCode.liveKey(in: content), key)
        XCTAssertNil(PairingCode.liveKey(in: PairingCode.qrContent(token: token)))
        // QR codes from before ids carry the key alone.
        XCTAssertEqual(PairingCode.liveKey(in: "dogmonitor://pair?t=\(token)&k=\(key.encoded)"), LiveKey(encoded: key.encoded))
    }

    func testInviteLinkCarriesTheKeyInTheFragment() throws {
        let key = LiveKey.generate()
        let link = try XCTUnwrap(PairingCode.inviteLink(token: token, baseURL: URL(string: "https://api.dogmonitor.app")!, liveKey: key))
        let id = try XCTUnwrap(key.id)
        XCTAssertEqual(link.absoluteString, "https://api.dogmonitor.app/invite/\(token)#k=\(key.encoded)&kid=\(id)")
        XCTAssertNil(link.query, "the key must not be in anything a server receives")
        XCTAssertEqual(PairingCode.parse(link.absoluteString), token)
        XCTAssertEqual(PairingCode.liveKey(in: link.absoluteString), key)
        XCTAssertEqual(PairingCode.liveKey(in: "https://api.dogmonitor.app/invite/\(token)#x=1&kid=\(id)&k=\(key.encoded)"), key)
        XCTAssertEqual(PairingCode.liveKey(in: "https://api.dogmonitor.app/invite/\(token)#k=\(key.encoded)"), LiveKey(encoded: key.encoded))
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

    func testAReplacedKeyNeedsANewScan() throws {
        let key = LiveKey.generate()
        let id = try XCTUnwrap(key.id)
        XCTAssertEqual(LiveEncryption.mode(key: key, householdEncrypted: true, householdKeyId: id), .encrypted(key))
        XCTAssertEqual(LiveEncryption.mode(key: key, householdEncrypted: true, householdKeyId: "the-new-key"), .needsKey)
        XCTAssertEqual(LiveEncryption.mode(key: key, householdEncrypted: true, householdKeyId: nil), .encrypted(key))
        XCTAssertEqual(LiveEncryption.mode(key: nil, householdEncrypted: true, householdKeyId: id), .needsKey)
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

    func testOwnerActions() throws {
        let key = LiveKey.generate()
        let id = try XCTUnwrap(key.id)
        let legacy = try XCTUnwrap(LiveKey(encoded: key.encoded))
        func action(_ key: LiveKey?, encrypted: Bool, keyId: String? = nil, rotate: Bool = false) -> LiveEncryption.OwnerAction {
            LiveEncryption.ownerAction(key: key, householdEncrypted: encrypted, householdKeyId: keyId, rotationNeeded: rotate)
        }
        XCTAssertEqual(action(nil, encrypted: false), .createKey)
        XCTAssertEqual(action(key, encrypted: false), .markEncrypted)
        XCTAssertEqual(action(key, encrypted: true, keyId: id), LiveEncryption.OwnerAction.none)
        XCTAssertEqual(action(nil, encrypted: true), .replaceLostKey)
        XCTAssertEqual(action(nil, encrypted: true, keyId: id, rotate: true), .replaceLostKey)
        // Someone holding the key left.
        XCTAssertEqual(action(key, encrypted: true, keyId: id, rotate: true), .rotateKey)
        XCTAssertEqual(action(legacy, encrypted: true, rotate: true), .rotateKey)
        // The server doesn't know this key's id yet (made before, or the earlier mark failed).
        XCTAssertEqual(action(key, encrypted: true), .markEncrypted)
        XCTAssertEqual(action(key, encrypted: true, keyId: "an-older-key"), .markEncrypted)
        // Keys from before ids stay as they are until someone leaves.
        XCTAssertEqual(action(legacy, encrypted: true), LiveEncryption.OwnerAction.none)
        XCTAssertEqual(action(legacy, encrypted: true, keyId: id), .rotateKey)
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
        XCTAssertNil(encrypted.liveKeyId)
        let named = try await api("{\(base),\"encrypted\":true,\"liveKeyId\":\"key-id-1234\"}").liveToken(cameraId: cameraId)
        XCTAssertEqual(named.liveKeyId, "key-id-1234")
    }

    func testHouseholdSaysWhenTheOwnerShouldMakeANewKey() async throws {
        let json = #"{"id":"\#(Fixtures.householdID)","name":"Home","plan":"free","ownerId":"\#(Fixtures.householdID)","role":"owner","liveEncrypted":true,"liveKeyId":"key-id-1234","liveKeyRotationNeeded":true,"members":[],"dogs":[],"devices":[]}"#
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .user(token: "t"), transport: StubTransport(json: json))
        let household = try await api.household()
        XCTAssertEqual(household.liveKeyId, "key-id-1234")
        XCTAssertEqual(household.liveKeyRotationNeeded, true)
    }

    func testMarkingSendsTheKeyIDButNeverTheKey() async throws {
        let stub = StubTransport(json: #"{"id":"\#(Fixtures.householdID)","name":"Home","plan":"free","liveEncrypted":true}"#)
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .user(token: "t"), transport: stub)
        try await api.markLiveEncrypted(keyId: "key-id-1234")
        let body = try Fixtures.bodyJSON(try XCTUnwrap(stub.requests.first))
        XCTAssertEqual(Set(body.keys), ["liveEncrypted", "liveKeyId"])
        XCTAssertEqual(body["liveKeyId"] as? String, "key-id-1234")
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
