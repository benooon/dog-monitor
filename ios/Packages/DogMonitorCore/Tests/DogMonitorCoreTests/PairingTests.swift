import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import DogMonitorCore

final class PairingCodeTests: XCTestCase {
    private let token = "AbCdEfGhIjKlMnOpQrStUvWxYz012-_9"

    func testQRContentRoundTrips() {
        let content = PairingCode.qrContent(token: token)
        XCTAssertEqual(content, "dogmonitor://pair?t=\(token)")
        XCTAssertEqual(PairingCode.parse(content), token)
    }

    func testParsesCodesTypedLoosely() {
        XCTAssertEqual(PairingCode.parse("123456"), "123456")
        XCTAssertEqual(PairingCode.parse(" 123 456 "), "123456")
        XCTAssertEqual(PairingCode.parse("123-456"), "123456")
        XCTAssertEqual(PairingCode.parse("012345"), "012345")
        XCTAssertNil(PairingCode.parse("12345"))
        XCTAssertNil(PairingCode.parse("١٢٣٤٥٦"), "only ASCII digits are sent to the backend")
    }

    func testParsesLinksAndBareTokens() {
        XCTAssertEqual(PairingCode.parse("https://dogmonitor.app/pair?t=\(token)"), token)
        XCTAssertEqual(PairingCode.parse(token), token)
        XCTAssertNil(PairingCode.parse("https://example.com/other?t=\(token)"))
        XCTAssertNil(PairingCode.parse("dogmonitor://pair"))
        XCTAssertNil(PairingCode.parse("dogmonitor://pair?t=bad token"))
        XCTAssertNil(PairingCode.parse("http://evil.example/pair?t=\(token)"))
        XCTAssertNil(PairingCode.parse("hello"))
        XCTAssertNil(PairingCode.parse(""))
    }

    func testInviteLinksRoundTrip() throws {
        let link = try XCTUnwrap(PairingCode.inviteLink(token: token, baseURL: URL(string: "https://api.dogmonitor.app/v1?x=1")!))
        XCTAssertEqual(link.absoluteString, "https://api.dogmonitor.app/invite/\(token)")
        XCTAssertEqual(PairingCode.parse(link.absoluteString), token)
        XCTAssertNil(PairingCode.parse("https://api.dogmonitor.app/invite/"))
        XCTAssertNil(PairingCode.parse("https://api.dogmonitor.app/invite/bad%20token"))
        XCTAssertNil(PairingCode.parse("http://evil.example/invite/\(token)"))
    }

    func testRemoveMemberSendsDelete() async throws {
        let stub = StubTransport(status: 204, json: "")
        let api = DogMonitorAPI(baseURL: Fixtures.baseURL, credential: .user(token: "t"), transport: stub)
        try await api.removeMember(userId: try XCTUnwrap(UUID(uuidString: Fixtures.userID)))
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/v1/household/members/\(Fixtures.userID)")
    }
}

final class InviteCountdownTests: XCTestCase {
    func testCountsDownAndExpires() {
        let start = Date(timeIntervalSince1970: 1_000)
        let countdown = InviteCountdown(expiresAt: start + 600)
        XCTAssertEqual(countdown.label(at: start), "10:00")
        XCTAssertEqual(countdown.label(at: start + 0.5), "10:00")
        XCTAssertEqual(countdown.label(at: start + 61), "8:59")
        XCTAssertFalse(countdown.isExpired(at: start + 599))
        XCTAssertTrue(countdown.isExpired(at: start + 600))
        XCTAssertEqual(countdown.label(at: start + 700), "0:00")
    }
}
