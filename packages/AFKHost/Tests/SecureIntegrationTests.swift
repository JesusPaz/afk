#if os(macOS)
import XCTest
import Security
@testable import AFKCore
@testable import AFKHost

@MainActor final class SecureIntegrationTests: XCTestCase {
    func testSecurePairingRealPTYReconnectAndRevocation() async throws {
        guard let server = ProcessInfo.processInfo.environment["AFK_E2EE_TEST_URL"] else { throw XCTSkip("requires the local v2 relay and PostgreSQL") }
        let host = HostController(preferences: UserDefaults(suiteName: "AFK-secure-tests")!)
        let credentials = try HostSecret(id: ProcessInfo.processInfo.environment["AFK_E2EE_HOST_ID"] ?? UUID().uuidString, token: SecretStore.randomToken())
        let account = "secure-test-\(UUID().uuidString)"
        let phone = SecurePhoneRelay(account: account)
        var testAccounts = [account, "host-trust-v2:\(try canonicalServer(server)):\(credentials.id)"]
        defer {
            phone.disconnect(); host.shutdown()
            for account in testAccounts {
                SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.jesuspaz.afk.poc", kSecAttrAccount as String: account] as CFDictionary)
            }
        }
        await host.connect(server: server, credentials: credentials)
        XCTAssertNil(host.error)
        try await until { host.relay.status == L10n.text("Conectado") }
        await host.makePairing()
        let invite = try XCTUnwrap(host.pairing)
        let invitation = try SecureInvitation.decode(invite.secret)
        try await rejectedBeforeAuthorization(host: host, invitation: invitation, wrongContext: true)
        try await rejectedBeforeAuthorization(host: host, invitation: invitation, wrongContext: false)
        var received: [Message] = []
        phone.onMessage = { received.append($0) }
        let saved = try await phone.pair(invitation: invite.secret)
        try await until { received.contains { $0.type == "welcome" } }
        XCTAssertEqual(host.relay.clients.count, 1)
        // The terminal is a real PTY; only the authenticated phone can take its lease.
        let session = try XCTUnwrap(host.create(name: "Secure integration"))
        phone.send(Message("claim", sessionID: session.id))
        try await until { session.lease.owner == saved.credentials.clientID }
        var input = Message("input", sessionID: session.id)
        input.epoch = session.lease.epoch; input.sequence = 1
        input.data = Data("printf 'AFK_SECURE_%s\\n' OK\n".utf8).base64EncodedString()
        phone.send(input)
        try await until {
            let output = received.filter { $0.type == "output" }.compactMap { $0.data.flatMap { Data(base64Encoded: $0) } }.reduce(Data(), +)
            return String(decoding: output, as: UTF8.self).contains("AFK_SECURE_OK")
        }
        // A second device cannot reuse the consumed invitation.
        let intruderAccount = "secure-test-\(UUID().uuidString)"; testAccounts.append(intruderAccount)
        let intruder = SecurePhoneRelay(account: intruderAccount)
        defer { intruder.disconnect() }
        var intruderAuthorized = false
        intruder.onMessage = { if $0.type == "welcome" { intruderAuthorized = true } }
        do { _ = try await intruder.pair(invitation: invite.secret); XCTFail("Consumed invitation accepted") } catch { XCTAssertFalse(intruderAuthorized) }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(intruderAuthorized); XCTAssertEqual(host.relay.clients.count, 1)
        await host.makePairing()
        let secondAccount = "secure-test-\(UUID().uuidString)"; testAccounts.append(secondAccount)
        let second = SecurePhoneRelay(account: secondAccount)
        defer { second.disconnect() }
        var secondMessages: [Message] = []
        second.onMessage = { secondMessages.append($0) }
        let secondSaved = try await second.pair(invitation: XCTUnwrap(host.pairing).secret)
        try await until { secondMessages.contains { $0.type == "welcome" } }
        second.send(Message("attach", sessionID: session.id))
        try await until { secondMessages.contains { $0.type == "snapshot" } }
        second.send(Message("claim", sessionID: session.id))
        try await until { session.lease.owner == secondSaved.credentials.clientID }
        // Old owner input is rejected even though that device remains authenticated.
        input.sequence = 2; input.data = Data("printf FORBIDDEN_STALE_OWNER\n".utf8).base64EncodedString()
        phone.send(input)
        var resize = Message("resize", sessionID: session.id)
        resize.epoch = session.lease.epoch; resize.sequence = 1; resize.columns = 91; resize.rows = 31
        second.send(resize)
        try await until { session.feed.size.columns == 91 }
        XCTAssertFalse(secondMessages.contains { $0.data.flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self).contains("FORBIDDEN_STALE_OWNER") } ?? false })
        await host.revoke(secondSaved.credentials.clientID)
        phone.disconnect(); received = []
        _ = try phone.restore(); phone.connect()
        try await until { received.contains { $0.type == "welcome" } }
        await host.revoke(saved.credentials.clientID)
        XCTAssertTrue(host.relay.clients.isEmpty)
        received = []; phone.connect()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(received.contains { $0.type == "welcome" })
        XCTAssertNotEqual(session.lease.owner, saved.credentials.clientID)
    }
    private func rejectedBeforeAuthorization(host: HostController, invitation: SecureInvitation, wrongContext: Bool) async throws {
        let token = try SecretStore.randomToken(), id = UUID().uuidString
        let api = RelayClient(), identity = try DeviceIdentity.create()
        let _: HostIdentity = try await api.request(URL(string: invitation.server)!, path: "v2/clients", body: ["id": id, "token": token, "code": invitation.code, "name": "Rejected test"])
        let wire = SecureTransport(); defer { wire.close() }
        var closed = false, accepted = false
        wire.onClose = { closed = true }
        wire.onPacket = { if $0.type == "welcome" { accepted = true } }
        wire.onReady = { _ in
            if wrongContext {
                var packet = SecurePacket(type: "hello")
                packet.server = "https://different-origin.invalid"; packet.hostID = invitation.hostID
                packet.clientID = id; packet.nonce = token; packet.invitationID = invitation.id; packet.secret = invitation.secret
                wire.send(packet)
            } else {
                var packet = SecurePacket(type: "message"); packet.message = Message("create", sessionID: UUID().uuidString)
                wire.send(packet)
            }
        }
        try await wire.connect(base: URL(string: invitation.server)!, path: "v2/connect", token: token, identity: identity, server: false, accepts: { DeviceIdentity.fingerprint($0) == invitation.fingerprint })
        try await until { closed }
        XCTAssertFalse(accepted); XCTAssertTrue(host.relay.clients.isEmpty); XCTAssertTrue(host.sessions.isEmpty)
    }
    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }; try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Secure integration condition timed out", file: file, line: line)
        throw SecureError.disconnected
    }
}
#endif
