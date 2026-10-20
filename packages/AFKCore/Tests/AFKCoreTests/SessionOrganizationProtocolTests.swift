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
        session.group = SessionGroup(name: "Load testing", symbol: "diamond", color: "teal", emoji: "🛠️")
        session.context = "fixture-project"; session.canRemove = true; session.closing = false
        let data = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(SessionInfo.self, from: data), session)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["id"] as? String, "stable-id")
        XCTAssertEqual(object["name"] as? String, "Investigate p95")
    }
    func testLegacyGroupDecodesWithoutEmoji() throws {
        let data = Data(#"{"id":"old","name":"Work","symbol":"folder","color":"blue"}"#.utf8)
        let group = try JSONDecoder().decode(SessionGroup.self, from: data)
        XCTAssertNil(group.emoji)
        XCTAssertEqual(group.symbol, "folder")
    }
    func testEmojiAcceptsOneComposedCharacterAndRejectsTextOrControls() {
        for value in ["🛠️", "👩🏽‍💻", "🇨🇴", "☀️", "⭐", "1️⃣", "#️⃣"] {
            XCTAssertEqual(SessionGroup.cleanEmoji(value), value)
        }
        for value in ["", "x", "1", "hello", "⭐🌙", "⭐\n", "\u{1b}⭐"] {
            XCTAssertNil(SessionGroup.cleanEmoji(value))
        }
    }

}
