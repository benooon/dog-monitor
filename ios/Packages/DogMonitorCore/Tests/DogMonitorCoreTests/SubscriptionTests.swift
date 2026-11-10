import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import DogMonitorCore

final class SubscriptionTests: XCTestCase {
    private static let freeFullJSON = """
    {"plan":"free","expiresAt":null,"productId":null,"limits":{"cameras":1},"usage":{"cameras":1}}
    """

    private static let premiumJSON = """
    {"plan":"premium","expiresAt":"2026-12-10T07:00:00.000Z",
     "productId":"com.benooon.dogmonitor.premium.monthly","limits":{"cameras":4},"usage":{"cameras":2}}
    """

    func testSubscriptionDecodesFreePlanAtItsLimit() async throws {
        let stub = StubTransport(json: Self.freeFullJSON)
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .user(token: "jwt"), transport: stub)

        let subscription = try await api.subscription()

        XCTAssertEqual(subscription.plan, .free)
        XCTAssertNil(subscription.expiresAt)
        XCTAssertFalse(subscription.isPremium)
        XCTAssertEqual(subscription.camerasLeft, 0)
        XCTAssertFalse(subscription.canPairCamera)
        XCTAssertTrue(subscription.suggestsUpgrade)

        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/subscription")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer jwt")
    }

    func testReportAppleTransactionPostsTheSignedTransaction() async throws {
        let stub = StubTransport(json: Self.premiumJSON)
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .user(token: "jwt"), transport: stub)

        let subscription = try await api.reportAppleTransaction("header.payload.signature")

        XCTAssertTrue(subscription.isPremium)
        XCTAssertEqual(subscription.productId, SubscriptionProducts.monthly)
        XCTAssertEqual(subscription.camerasLeft, 2)
        XCTAssertTrue(subscription.canPairCamera)
        XCTAssertFalse(subscription.suggestsUpgrade)
        XCTAssertEqual(subscription.expiresAt, JSONCoding.parseISO8601("2026-12-10T07:00:00.000Z"))

        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/subscription/apple")
        let body = try Fixtures.bodyJSON(request)
        XCTAssertEqual(body["signedTransaction"] as? String, "header.payload.signature")
        XCTAssertEqual(body.count, 1)
    }

    func testSubscriptionInUseSurfacesItsCode() async throws {
        let stub = StubTransport(status: 409, json: #"{"error":"subscription_in_use"}"#)
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .user(token: "jwt"), transport: stub)

        do {
            _ = try await api.reportAppleTransaction("header.payload.signature")
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error, .http(status: 409, code: "subscription_in_use"))
            XCTAssertEqual(error.code, "subscription_in_use")
            XCTAssertFalse(error.isCameraLimitReached)
        }
    }

    func testCameraLimitReachedIsRecognized() {
        XCTAssertTrue(APIError.http(status: 409, code: "camera_limit_reached").isCameraLimitReached)
        XCTAssertFalse(APIError.http(status: 409, code: "viewer_limit_reached").isCameraLimitReached)
        XCTAssertNil(APIError.transport("offline").code)
    }

    func testUnknownPlanReadsAsFree() throws {
        let json = #"{"plan":"family","expiresAt":null,"productId":null,"limits":{"cameras":2},"usage":{"cameras":0}}"#
        let subscription = try JSONCoding.makeDecoder().decode(SubscriptionDTO.self, from: Data(json.utf8))
        XCTAssertEqual(subscription.plan, .free)
        XCTAssertEqual(subscription.camerasLeft, 2)
    }

    func testOverLimitAfterDowngradeHasNoCamerasLeft() {
        let subscription = SubscriptionDTO(
            plan: .free, expiresAt: nil, productId: nil,
            limits: .init(cameras: 1), usage: .init(cameras: 3)
        )
        XCTAssertEqual(subscription.camerasLeft, 0)
        XCTAssertTrue(subscription.suggestsUpgrade)
    }

    func testPremiumAtItsLimitDoesNotSuggestUpgrade() {
        let subscription = SubscriptionDTO(
            plan: .premium, expiresAt: nil, productId: SubscriptionProducts.yearly,
            limits: .init(cameras: 4), usage: .init(cameras: 4)
        )
        XCTAssertFalse(subscription.canPairCamera)
        XCTAssertFalse(subscription.suggestsUpgrade)
    }

    func testProductIds() {
        XCTAssertEqual(SubscriptionProducts.all.first, SubscriptionProducts.yearly)
        XCTAssertTrue(SubscriptionProducts.isPremium(SubscriptionProducts.monthly))
        XCTAssertFalse(SubscriptionProducts.isPremium("com.example.other"))
    }
}
