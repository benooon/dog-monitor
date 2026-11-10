import DogMonitorCore
import XCTest
@testable import DogMonitor

@MainActor
final class HouseholdTests: XCTestCase {
    private let token = "AbCdEfGhIjKlMnOpQrStUvWxYz012-_9"

    func testInviteLinkOpensTheJoinFlow() throws {
        let router = DeepLinkRouter()
        router.handle(try XCTUnwrap(URL(string: "https://api.dogmonitor.app/invite/\(token)")))
        XCTAssertEqual(router.pendingInvite, token)
    }

    func testUnrelatedLinksAreIgnored() throws {
        let router = DeepLinkRouter()
        router.handle(try XCTUnwrap(URL(string: "https://api.dogmonitor.app/other")))
        XCTAssertNil(router.pendingInvite)
    }

    func testNoShareableLinkForALocalServer() {
        let model = ViewerSessionModel(baseURL: URL(string: "http://localhost:1")!, store: InMemorySecureStore())
        let invite = InviteDTO(token: token, code: "123456", expiresAt: .now)
        XCTAssertNil(model.inviteLink(for: invite))
    }

    func testMemberWithoutANameHasAFallback() {
        let member = MemberDTO(userId: UUID(), name: nil, role: .member)
        XCTAssertFalse(HouseholdView.displayName(of: member).isEmpty)
    }
}
