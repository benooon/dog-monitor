import DogMonitorCore
import XCTest
@testable import DogMonitor

@MainActor
final class ViewerSessionModelTests: XCTestCase {
    func testStartsSignedOutWithoutStoredCredential() async {
        let model = ViewerSessionModel(baseURL: URL(string: "http://localhost:1")!, store: InMemorySecureStore())
        await model.restore()
        XCTAssertEqual(model.state, .signedOut)
    }

    func testSignOutClearsStoredCredential() throws {
        let store = InMemorySecureStore()
        try CredentialStore(store: store).save(.user(token: "jwt"))
        let model = ViewerSessionModel(baseURL: URL(string: "http://localhost:1")!, store: store)
        model.signOut()
        XCTAssertEqual(model.state, .signedOut)
        XCTAssertEqual(CredentialStore(store: store).load(), .none)
    }

    func testAPIBaseURLComesFromInfoPlist() {
        // API_BASE_URL in project.yml (the Railway backend), not the localhost fallback.
        XCTAssertEqual(AppConfig.apiBaseURL.scheme, "https")
        XCTAssertNotEqual(AppConfig.apiBaseURL.host(), "localhost")
    }
}

final class AppleNonceTests: XCTestCase {
    func testSHA256MatchesKnownVector() {
        // echo -n abc | shasum -a 256
        XCTAssertEqual(AppleNonce(raw: "abc").sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testRandomNoncesAreLongAndDistinct() {
        let a = AppleNonce.random(), b = AppleNonce.random()
        XCTAssertNotEqual(a, b)
        XCTAssertGreaterThanOrEqual(a.raw.count, 32)
        XCTAssertFalse(a.raw.contains("="))
    }
}
