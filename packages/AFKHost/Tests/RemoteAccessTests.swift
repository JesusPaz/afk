#if os(macOS)
import XCTest
import AFKCore
@testable import AFKHost

@MainActor final class RemoteAccessTests: XCTestCase {
    func testDefaultPrivateAndIndependentDeviceSessionPermissions() {
        let access = RemoteAccess()
        XCTAssertEqual(access.level(client: "phone", session: "one"), .none)
        XCTAssertFalse(access.canCreate(client: "phone"))
        access.set(client: "phone", session: "one", level: .readOnly, duration: 60)
        XCTAssertEqual(access.level(client: "phone", session: "one"), .readOnly)
        XCTAssertEqual(access.level(client: "other", session: "one"), .none)
        XCTAssertEqual(access.level(client: "phone", session: "two"), .none)
        XCTAssertFalse(access.canClose(client: "phone", session: "one"))
        access.set(client: "phone", session: "one", level: .none, duration: 60)
        XCTAssertEqual(access.level(client: "phone", session: "one"), .none)
    }
    func testOfflineAuthorizationExpiresWithoutClaimAndCannotBeRevivedByClockRollback() {
        var date = Date(), uptime = 10.0
        let access = RemoteAccess(now: { date }, uptime: { uptime })
        access.set(client: "p", session: "s", level: .control, duration: 60, allowClose: true)
        date = date.addingTimeInterval(60)
        XCTAssertEqual(access.level(client: "p", session: "s"), .readOnly)
        XCTAssertFalse(access.canClose(client: "p", session: "s"))
        XCTAssertFalse(access.expire().isEmpty)
        date = date.addingTimeInterval(-120); uptime += 1
        XCTAssertEqual(access.level(client: "p", session: "s"), .readOnly)
        XCTAssertFalse(access.canClose(client: "p", session: "s"))
    }
    func testIdleCannotBeExtendedByRepeatedClaimOrReconnect() {
        var uptime = 0.0
        let access = RemoteAccess(uptime: { uptime })
        access.set(client: "p", session: "s", level: .control, duration: 3600)
        uptime = 1000 // preauthorized offline; idle time starts on first claim
        XCTAssertEqual(access.level(client: "p", session: "s"), .control)
        access.claimed(client: "p", session: "s")
        uptime = 1299; access.claimed(client: "p", session: "s")
        uptime = 1300
        XCTAssertEqual(access.level(client: "p", session: "s"), .readOnly)
        access.claimed(client: "p", session: "s"); access.acceptedInput(client: "p", session: "s")
        XCTAssertEqual(access.level(client: "p", session: "s"), .readOnly)
    }
    func testAcceptedInputExtendsIdleButNotAbsoluteAuthorization() {
        var uptime = 0.0
        let access = RemoteAccess(uptime: { uptime })
        access.set(client: "p", session: "s", level: .control, duration: 600)
        access.claimed(client: "p", session: "s")
        uptime = 250; access.acceptedInput(client: "p", session: "s")
        uptime = 500; access.acceptedInput(client: "p", session: "s")
        uptime = 599; XCTAssertEqual(access.level(client: "p", session: "s"), .control)
        uptime = 600; XCTAssertEqual(access.level(client: "p", session: "s"), .readOnly)
    }
    func testCreationIsExplicitAndNeverExtendsDeadlineOrGrantsTerminate() {
        var uptime = 0.0
        let access = RemoteAccess(uptime: { uptime })
        access.setCreation(client: "p", duration: 60)
        uptime = 50; access.created(client: "p", session: "new")
        XCTAssertEqual(access.level(client: "p", session: "new"), .control)
        XCTAssertFalse(access.canClose(client: "p", session: "new"))
        uptime = 60
        XCTAssertFalse(access.canCreate(client: "p"))
        XCTAssertEqual(access.level(client: "p", session: "new"), .readOnly)
        access.removeAll()
        XCTAssertEqual(access.level(client: "p", session: "new"), .none)
    }
    func testHostChecksAllOperationsAndPrivateMetadata() throws {
        let prefs = UserDefaults(suiteName: UUID().uuidString)!
        var uptime = 0.0
        let access = RemoteAccess(uptime: { uptime })
        let host = HostController(preferences: prefs, access: access)
        defer { host.shutdown() }
        let session = try XCTUnwrap(host.create())
        let client = UUID().uuidString
        func send(_ type: String, id: String? = nil) {
            var m = Message(type, sessionID: id ?? session.id); m.clientID = client
            m.epoch = session.lease.epoch; m.sequence = 1
            m.data = Data("FORBIDDEN".utf8).base64EncodedString(); m.columns = 91; m.rows = 31
            host.receive(m)
        }
        send("clientConnected")
        XCTAssertTrue(host.visibleSessions(for: client).isEmpty)
        for type in ["attach", "claim", "input", "resize", "terminate", "create"] { send(type) }
        XCTAssertEqual(host.sessions.count, 1); XCTAssertTrue(session.running); XCTAssertEqual(session.lease.owner, "local")
        access.set(client: client, session: session.id, level: .readOnly, duration: 3600)
        XCTAssertEqual(host.visibleSessions(for: client).count, 1)
        for type in ["claim", "input", "resize", "terminate"] { send(type) }
        XCTAssertEqual(session.lease.owner, "local"); XCTAssertEqual(session.feed.size, .initial)
        access.set(client: client, session: session.id, level: .control, duration: 3600)
        send("claim"); XCTAssertEqual(session.lease.owner, client)
        uptime = 299; send("renew"); send("claim")
        // Wrong epoch input does not count as activity.
        var stale = Message("input", sessionID: session.id); stale.clientID = client; stale.epoch = 0; stale.sequence = 1; stale.data = Data("ignored".utf8).base64EncodedString()
        host.receive(stale)
        uptime = 300; send("renew")
        XCTAssertEqual(access.level(client: client, session: session.id), .readOnly)
        XCTAssertNotEqual(session.lease.owner, client)
        send("clientDisconnected"); send("clientConnected"); send("claim")
        XCTAssertNotEqual(session.lease.owner, client)
        host.stopRemoteAccess(); XCTAssertTrue(host.visibleSessions(for: client).isEmpty)
        XCTAssertTrue(session.running)
        XCTAssertTrue(host.accessEvents.contains { $0.kind == .denied })
        let restored = HostController(preferences: prefs)
        defer { restored.shutdown() }
        XCTAssertTrue(restored.accessEvents.contains { $0.kind == .stopped })
        XCTAssertEqual(restored.access.level(client: client, session: session.id), .none)
    }
    func testCreationCannotAdoptExistingSessionAndCloseRequiresSeparatePermission() throws {
        let host = HostController(preferences: UserDefaults(suiteName: UUID().uuidString)!)
        defer { host.shutdown() }
        let client = UUID().uuidString, existing = try XCTUnwrap(host.create())
        var connect = Message("clientConnected"); connect.clientID = client; host.receive(connect)
        host.access.setCreation(client: client, duration: 60)
        var create = Message("create", sessionID: existing.id); create.clientID = client; host.receive(create)
        XCTAssertEqual(host.access.level(client: client, session: existing.id), .none)
        let id = UUID().uuidString; create.sessionID = id; host.receive(create)
        let created = try XCTUnwrap(host.sessions.first { $0.id == id })
        XCTAssertEqual(host.access.level(client: client, session: id), .control)
        XCTAssertEqual(host.access.level(client: "another", session: id), .none)
        var close = Message("terminate", sessionID: id); close.clientID = client; host.receive(close)
        XCTAssertTrue(created.running)
        host.access.set(client: client, session: id, level: .readOnly, duration: 60, allowClose: true)
        host.receive(close); XCTAssertFalse(created.running); XCTAssertTrue(existing.running)
    }
    func testHistoryIsBoundedAndNeverContainsTerminalData() throws {
        let prefs = UserDefaults(suiteName: UUID().uuidString)!
        let history = AccessHistory(preferences: prefs)
        for _ in 0..<205 { history.record(.connected, client: "device") }
        XCTAssertEqual(history.events.count, 200)
        XCTAssertEqual(AccessHistory(preferences: prefs).events.count, 200)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: prefs.data(forKey: "remoteAccessHistory")!) as? [[String: Any]])
        XCTAssertEqual(Set(keys[0].keys), Set(["id", "date", "kind", "client"]))
    }
}
#endif
