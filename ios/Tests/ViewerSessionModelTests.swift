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
        XCTAssertEqual(AppConfig.apiBaseURL.scheme, "http")
    }
}
