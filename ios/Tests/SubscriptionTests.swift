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

    func testStoreIsReadyWhenTheAppStoreReturnsProducts() async {
        let model = makeModel { ids in ids.count }
        XCTAssertEqual(model.storeState, .loading)
        await model.loadProducts()
        XCTAssertEqual(model.storeState, .ready)
    }

    func testStoreIsUnavailableWhenNoProductsComeBack() async {
        let model = makeModel { _ in 0 }
        await model.loadProducts()
        XCTAssertEqual(model.storeState, .unavailable)
    }

    func testStoreIsUnavailableWhenLoadingFailsAndCanTryAgain() async {
        let attempts = Attempts()
        let model = makeModel { ids in
            if await attempts.next() == 1 { throw URLError(.notConnectedToInternet) }
            return ids.count
        }
        await model.loadProducts()
        XCTAssertEqual(model.storeState, .unavailable)
        await model.loadProducts()
        XCTAssertEqual(model.storeState, .ready)
    }

    func testStoreAsksForThePremiumProducts() async {
        let asked = Asked()
        let model = makeModel { ids in
            await asked.set(ids)
            return ids.count
        }
        await model.loadProducts()
        let ids = await asked.ids
        XCTAssertEqual(ids, SubscriptionProducts.all)
    }

    private func makeModel(_ loader: @escaping SubscriptionModel.ProductLoader) -> SubscriptionModel {
        SubscriptionModel(api: DogMonitorAPI(baseURL: URL(string: "http://localhost:1")!), householdId: UUID(), productLoader: loader)
    }

    func testSignedOutSessionHasNoSubscription() {
        let model = ViewerSessionModel(baseURL: URL(string: "http://localhost:1")!, store: InMemorySecureStore())
        model.signOut()
        XCTAssertNil(model.subscription)
    }
}

private actor Attempts {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

private actor Asked {
    private(set) var ids: [String] = []
    func set(_ ids: [String]) { self.ids = ids }
}
