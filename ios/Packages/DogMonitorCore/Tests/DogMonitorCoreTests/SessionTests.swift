import Foundation
import XCTest
@testable import DogMonitorCore

final class CredentialStoreTests: XCTestCase {
    func testRoundTripsUserAndDeviceCredentials() throws {
        let store = CredentialStore(store: InMemorySecureStore())
        XCTAssertEqual(store.load(), .none)

        try store.save(.user(token: "jwt"))
        XCTAssertEqual(store.load(), .user(token: "jwt"))

        let id = UUID()
        try store.save(.device(id: id, secret: "s"))
        XCTAssertEqual(store.load(), .device(id: id, secret: "s"))

        try store.clear()
        XCTAssertEqual(store.load(), .none)
    }

    func testCorruptDataLoadsAsSignedOut() throws {
        let secure = InMemorySecureStore()
        try secure.setData(Data("garbage".utf8), forKey: CredentialStore.key)
        XCTAssertEqual(CredentialStore(store: secure).load(), .none)
    }
}

final class OnboardingStateTests: XCTestCase {
    private let user = UserDTO(id: UUID(), name: "Ben")

    func testNeedsHouseholdWhenUserHasNone() {
        XCTAssertEqual(OnboardingState.from(MeResponse(user: user, households: [])), .needsHousehold(user: user))
    }

    func testReadyWithFirstHousehold() {
        let home = HouseholdMembershipDTO(id: UUID(), name: "Home", role: .owner)
        XCTAssertEqual(OnboardingState.from(MeResponse(user: user, households: [home])), .ready(user: user, household: home))
    }

    func testHouseholdNameValidation() {
        XCTAssertEqual(HouseholdNameRules.validated("  The Cohens  "), "The Cohens")
        XCTAssertNil(HouseholdNameRules.validated("   "))
        XCTAssertNil(HouseholdNameRules.validated(String(repeating: "a", count: 101)))
    }
}
