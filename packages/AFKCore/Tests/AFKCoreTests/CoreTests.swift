import XCTest
@testable import AFKCore

final class CoreTests: XCTestCase {
    func testOnlyCurrentOwnerAndEpochCanWrite() {
        var lease = ControlLease(); let original = lease.epoch
        lease.claim("phone"); let remote = lease.epoch
        XCTAssertFalse(lease.accept(client: "local", epoch: original, sequence: 1))
        XCTAssertTrue(lease.accept(client: "phone", epoch: remote, sequence: 1))
        XCTAssertFalse(lease.accept(client: "phone", epoch: remote, sequence: 1))
        lease.claim("local")
        XCTAssertFalse(lease.accept(client: "phone", epoch: remote, sequence: 2))
        XCTAssertTrue(lease.accept(client: "local", epoch: lease.epoch, sequence: 1))
    }
    func testWrongClientCannotReleaseControl() {
        var lease = ControlLease(); lease.claim("phone"); lease.release("other")
        XCTAssertEqual(lease.owner, "phone"); lease.release("phone"); XCTAssertEqual(lease.owner, "")
    }
    func testOverflowFailsClosedInsteadOfReplayingBrokenANSI() {
        var buffer = ReplayBuffer(limit: 4); buffer.append(Data([27, 91, 51, 49]))
        XCTAssertNotNil(buffer.snapshot); buffer.append(Data([109])); XCTAssertNil(buffer.snapshot)
        XCTAssertTrue(buffer.data.isEmpty)
    }
    func testServerDoesNotAllowPlaintextRemoteOrCredentialURLs() {
        XCTAssertThrowsError(try ServerAddress.parse("http://example.com"))
        XCTAssertThrowsError(try ServerAddress.parse("https://user:secret@example.com"))
        XCTAssertThrowsError(try ServerAddress.parse("https://example.com?token=x"))
        XCTAssertNoThrow(try ServerAddress.parse("http://127.0.0.1:8787"))
        XCTAssertNoThrow(try ServerAddress.parse("https://relay.example.com"))
    }
    func testMessageWireContract() throws {
        let json = Data(#"{"type":"control","sessionID":"s","owner":"phone","epoch":7}"#.utf8)
        let message = try JSONDecoder().decode(Message.self, from: json)
        XCTAssertEqual(message.epoch, 7); XCTAssertEqual(message.owner, "phone")
        XCTAssertEqual(try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message)).sessionID, "s")
    }
}
