import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import DogMonitorCore

final class PlanFeaturesTests: XCTestCase {
    func testFreePlan() {
        let free = PlanFeatures.for(.free)
        XCTAssertEqual(free.cameras, 1)
        XCTAssertEqual(free.members, 2)
        XCTAssertEqual(free.clipRetentionDays, 1)
        XCTAssertFalse(free.insights)
        XCTAssertFalse(free.highlightReel)
    }

    func testPremiumPlan() {
        let premium = PlanFeatures.for(.premium)
        XCTAssertEqual(premium.cameras, 4)
        XCTAssertNil(premium.members, "everyone in the household watches")
        XCTAssertEqual(premium.clipRetentionDays, 30)
        XCTAssertTrue(premium.insights)
        XCTAssertTrue(premium.highlightReel)
    }

    func testClipRetentionByPlan() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hours = { (h: Double) in now.addingTimeInterval(-h * 3600) }
        XCTAssertTrue(PlanFeatures.free.keepsClip(startedAt: hours(23), now: now))
        XCTAssertFalse(PlanFeatures.free.keepsClip(startedAt: hours(25), now: now))
        XCTAssertTrue(PlanFeatures.premium.keepsClip(startedAt: hours(29 * 24), now: now))
        XCTAssertFalse(PlanFeatures.premium.keepsClip(startedAt: hours(31 * 24), now: now))
    }

    func testSubscriptionDecodesMemberCountsAndFeatures() throws {
        let json = """
        {"plan":"free","expiresAt":null,"productId":null,"limits":{"cameras":1,"members":2},"usage":{"cameras":0,"members":1}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let subscription = try decoder.decode(SubscriptionDTO.self, from: Data(json.utf8))
        XCTAssertEqual(subscription.limits.members, 2)
        XCTAssertEqual(subscription.usage.members, 1)
        XCTAssertEqual(subscription.features, .free)
    }

    func testOlderServerWithoutMemberCounts() throws {
        let json = #"{"plan":"premium","expiresAt":null,"productId":null,"limits":{"cameras":4},"usage":{"cameras":2}}"#
        let subscription = try JSONDecoder().decode(SubscriptionDTO.self, from: Data(json.utf8))
        XCTAssertNil(subscription.limits.members)
        XCTAssertEqual(subscription.features, .premium)
    }

    func testSoleDogName() {
        let householdId = UUID()
        let dog = { (name: String) in DogDTO(id: UUID(), householdId: householdId, name: name, createdAt: Date()) }
        let household = { (dogs: [DogDTO]) in
            HouseholdDTO(id: householdId, name: "Home", ownerId: UUID(), role: .owner, dogs: dogs)
        }
        XCTAssertEqual(household([dog("Rex")]).soleDogName, "Rex")
        XCTAssertNil(household([]).soleDogName)
        XCTAssertNil(household([dog("Rex"), dog("Bella")]).soleDogName)
    }
}
