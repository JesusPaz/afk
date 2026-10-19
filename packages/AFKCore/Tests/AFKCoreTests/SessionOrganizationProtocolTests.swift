import XCTest
@testable import AFKCore

final class SessionOrganizationProtocolTests: XCTestCase {
    func testLegacySessionListDecodesWithoutOrganizationOrRemovalCapability() throws {
        let data = Data(#"{"type":"sessions","sessions":[{"id":"old","name":"Terminal 1","running":true,"owner":"local","epoch":1}]}"#.utf8)
        let message = try JSONDecoder().decode(Message.self, from: data)
        let session = try XCTUnwrap(message.sessions?.first)
        XCTAssertNil(session.group); XCTAssertNil(session.context)
        XCTAssertNil(session.closing); XCTAssertNil(session.canRemove)
        XCTAssertEqual(session.name, "Terminal 1")
    }
    func testOrganizationRoundTripsWithoutChangingSessionIdentity() throws {
        var session = SessionInfo(id: "stable-id", name: "Investigate p95", running: true, owner: "local", epoch: 12)
        session.group = SessionGroup(name: "Load testing", symbol: "diamond", color: "teal")
        session.context = "fixture-project"; session.canRemove = true; session.closing = false
        let data = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(SessionInfo.self, from: data), session)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["id"] as? String, "stable-id")
        XCTAssertEqual(object["name"] as? String, "Investigate p95")
    }
}
