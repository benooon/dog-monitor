import DogMonitorCore
import SwiftUI
import XCTest
@testable import DogMonitor

@MainActor
final class PremiumAppTests: XCTestCase {
    func testCameraLimitHasItsOwnPairingMessage() {
        let message = CameraPairingView.message(for: APIError.http(status: 409, code: "camera_limit_reached"))
        XCTAssertEqual(
            message,
            LocalizedStringKey("This household has no room for another camera. The owner can get Premium on the Household screen.")
        )
        XCTAssertEqual(
            CameraPairingView.message(for: APIError.http(status: 404, code: nil)),
            LocalizedStringKey("This code is invalid or has expired.")
        )
    }

    func testSubscriptionModelStartsWithoutAStatus() {
        let householdId = UUID()
        let model = SubscriptionModel(api: DogMonitorAPI(baseURL: URL(string: "http://localhost:1")!), householdId: householdId)
        XCTAssertNil(model.status)
        XCTAssertEqual(model.householdId, householdId)
        XCTAssertFalse(model.isRestoring)
    }

    func testSignedOutSessionHasNoSubscription() {
        let model = ViewerSessionModel(baseURL: URL(string: "http://localhost:1")!, store: InMemorySecureStore())
        model.signOut()
        XCTAssertNil(model.subscription)
    }
}
