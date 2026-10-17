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
        try await rejectedBeforeAuthorization(host: host, invitation: invitation, wrongContext: false, legacy: true)
        var received: [Message] = []
        phone.onMessage = { received.append($0) }
        let saved = try await approvedPair(phone, invitation: invite.secret, host: host, waitPastHandshakeTimeout: true)
        try await until { received.contains { $0.type == "welcome" } }
        XCTAssertEqual(host.relay.clients.count, 1)
        // The terminal is a real PTY; only the authenticated phone can take its lease.
        let session = try XCTUnwrap(host.create(name: "Secure integration"))
        phone.send(Message("attach", sessionID: session.id))
        try await until { received.contains { $0.type == "error" } }
        XCTAssertFalse(received.contains { $0.sessionID == session.id && ["snapshot", "output"].contains($0.type) })
        XCTAssertFalse(received.contains { $0.sessions?.contains { $0.id == session.id } == true })
        host.setAccess(client: saved.credentials.clientID, session: session.id, level: .readOnly)
        try await until { received.contains { $0.sessions?.contains { $0.id == session.id && $0.canControl == false } == true } }
        received = []
        phone.send(Message("claim", sessionID: session.id))
        try await until { received.contains { $0.type == "error" } }
        XCTAssertEqual(session.lease.owner, "local")
        received = []
        phone.send(Message("create", sessionID: UUID().uuidString))
        try await until { received.contains { $0.type == "error" } }
        XCTAssertEqual(host.sessions.count, 1)
        received = []
        phone.send(Message("terminate", sessionID: session.id))
        try await until { received.contains { $0.type == "error" } }
        XCTAssertTrue(session.running)
        host.setAccess(client: saved.credentials.clientID, session: session.id, level: .control)
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
        let secondSaved = try await approvedPair(second, invitation: XCTUnwrap(host.pairing).secret, host: host)
        try await until { secondMessages.contains { $0.type == "welcome" } }
        XCTAssertFalse(secondMessages.contains { $0.sessions?.contains { $0.id == session.id } == true })
        host.setAccess(client: secondSaved.credentials.clientID, session: session.id, level: .control)
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
        // Removing read access immediately stops future output, not only snapshots.
        received = []
        host.setAccess(client: saved.credentials.clientID, session: session.id, level: .none)
        try await until { received.contains { $0.type == "sessions" && $0.sessions?.isEmpty == true } }
        // Earlier frames can already be in flight; the ordered permission update is the boundary.
        received = []
        var afterRemoval = Message("input", sessionID: session.id)
        afterRemoval.epoch = session.lease.epoch; afterRemoval.sequence = 2
        afterRemoval.data = Data("printf POST_REMOVAL_MARKER\n".utf8).base64EncodedString()
        second.send(afterRemoval)
        try await until { secondMessages.contains { $0.data.flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self).contains("POST_REMOVAL_MARKER") } ?? false } }
        XCTAssertFalse(received.contains { $0.sessionID == session.id && ["output", "snapshot", "resized", "control"].contains($0.type) })
        host.setAccess(client: saved.credentials.clientID, session: session.id, level: .control)
        // A peer cannot forge lifecycle events reserved for the authenticated transport.
        second.send(Message("clientConnected"))
        try await until { !host.connectedClients.contains(secondSaved.credentials.clientID) }
        second.connect()
        try await until { host.connectedClients.contains(secondSaved.credentials.clientID) }
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
    func testConsentCancellationConcurrencyAndPhonePersistence() async throws {
        try await withTestHost { host, accounts in
            try await pendingRejectionAndPersistenceFailure(host: host, accounts: &accounts)
        }
    }
    func testAllSessionCommandsRejectedWhilePending() async throws {
        try await withTestHost { host, _ in try await rejectedPendingCommands(host: host) }
    }
    private func withTestHost(_ operation: (HostController, inout [String]) async throws -> Void) async throws {
        guard let server = ProcessInfo.processInfo.environment["AFK_E2EE_TEST_URL"] else { throw XCTSkip("requires the local v2 relay and PostgreSQL") }
        let host = HostController(preferences: UserDefaults(suiteName: "AFK-secure-tests")!)
        let credentials = try HostSecret(id: ProcessInfo.processInfo.environment["AFK_E2EE_HOST_ID"] ?? UUID().uuidString, token: SecretStore.randomToken())
        var accounts = ["host-trust-v2:\(try canonicalServer(server)):\(credentials.id)"]
        defer {
            host.shutdown()
            for account in accounts {
                SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.jesuspaz.afk.poc", kSecAttrAccount as String: account] as CFDictionary)
            }
        }
        await host.connect(server: server, credentials: credentials)
        XCTAssertNil(host.error)
        try await until { host.relay.connected }
        try await operation(host, &accounts)
    }
    private func pendingRejectionAndPersistenceFailure(host: HostController, accounts: inout [String]) async throws {
        let account = "secure-test-\(UUID().uuidString)"; accounts.append(account)
        var failSave = false
        let phone = SecurePhoneRelay(account: account, persist: {
            if failSave { throw SecureError.persistence }
            try SecretStore.write($0, account: account)
        })
        defer { phone.disconnect() }
        await host.makePairing()
        let first = try await approvedPair(phone, invitation: XCTUnwrap(host.pairing).secret, host: host)
        phone.disconnect()
        await host.makePairing()
        let invitation = try XCTUnwrap(host.pairing).secret
        let task = Task { try await phone.pair(invitation: invitation) }
        try await until { phone.comparisonCode != nil }
        let candidate = try XCTUnwrap(host.relay.candidate)
        XCTAssertEqual(phone.saved?.credentials.clientID, first.credentials.clientID)
        let otherAccount = "secure-test-\(UUID().uuidString)"; accounts.append(otherAccount)
        let other = SecurePhoneRelay(account: otherAccount)
        defer { other.disconnect() }
        do { _ = try await other.pair(invitation: invitation); XCTFail("Second candidate replaced first") } catch {}
        XCTAssertEqual(host.relay.candidate?.id, candidate.id)
        XCTAssertEqual(host.relay.candidate?.code, phone.comparisonCode)
        try host.relay.cancelInvitation()
        do { _ = try await task.value; XCTFail("Rejected candidate accepted") } catch {}
        XCTAssertThrowsError(try host.relay.approvePairing(candidate.id))
        XCTAssertEqual(host.relay.clients.count, 1)
        XCTAssertEqual(phone.saved?.credentials.clientID, first.credentials.clientID)
        do { _ = try await phone.pair(invitation: invitation); XCTFail("Cancelled invitation reused") } catch {}
        await host.makePairing()
        let replacement = try XCTUnwrap(host.pairing).secret
        failSave = true
        do { _ = try await approvedPair(phone, invitation: replacement, host: host); XCTFail("Failed phone save reported success") } catch {}
        XCTAssertEqual(phone.saved?.credentials.clientID, first.credentials.clientID)
        let disk: SecurePhoneConnection = try XCTUnwrap(SecretStore.read(account))
        XCTAssertEqual(disk.credentials.clientID, first.credentials.clientID)
        XCTAssertEqual(host.relay.clients.count, 2) // Mac committed: orphan remains revocable.
        for client in host.relay.clients { try await host.relay.revoke(client.id) }
    }
    private func approvedPair(_ phone: SecurePhoneRelay, invitation: String, host: HostController, waitPastHandshakeTimeout: Bool = false) async throws -> SecurePhoneConnection {
        let previousCount = host.relay.clients.count
        var result: Result<SecurePhoneConnection, Error>?
        let task = Task {
            do { let saved = try await phone.pair(invitation: invitation); result = .success(saved); return saved }
            catch { result = .failure(error); throw error }
        }
        defer { task.cancel() }
        try await until { (host.relay.candidate != nil && phone.comparisonCode != nil) || result != nil }
        if let result { return try result.get() }
        let candidate = try XCTUnwrap(host.relay.candidate)
        XCTAssertEqual(candidate.code, phone.comparisonCode)
        XCTAssertEqual(host.relay.clients.count, previousCount)
        XCTAssertFalse(host.connectedClients.contains(candidate.clientID))
        if waitPastHandshakeTimeout {
            try await Task.sleep(for: .seconds(16))
            XCTAssertEqual(host.relay.candidate?.id, candidate.id)
            XCTAssertEqual(phone.comparisonCode, candidate.code)
            XCTAssertEqual(host.relay.clients.count, previousCount)
        }
        try host.relay.approvePairing(candidate.id)
        return try await task.value
    }
    private func rejectedPendingCommands(host: HostController) async throws {
        for command in ["list", "create", "attach", "input", "resize", "claim", "release", "renew", "terminate"] {
            await host.makePairing()
            let invitation = try SecureInvitation.decode(XCTUnwrap(host.pairing).secret)
            let id = UUID().uuidString, token = try SecretStore.randomToken(), identity = try DeviceIdentity.create()
            let _: HostIdentity = try await RelayClient().request(URL(string: invitation.server)!, path: "v2/clients",
                body: ["id": id, "token": token, "code": invitation.code, "name": "Pending test"])
            let wire = SecureTransport()
            var closed = false, leaked = false
            wire.onClose = { closed = true }
            wire.onReady = { _ in
                var hello = SecurePacket(type: "hello"); hello.server = invitation.server; hello.hostID = invitation.hostID
                hello.clientID = id; hello.nonce = token; hello.invitationID = invitation.id; hello.secret = invitation.secret
                hello.ceremony = 3
                wire.send(hello)
            }
            wire.onPacket = { packet in
                if packet.type == "approvalRequired" {
                    var message = SecurePacket(type: "message"); message.message = Message(command, sessionID: UUID().uuidString)
                    wire.send(message)
                } else { leaked = true }
            }
            try await wire.connect(base: URL(string: invitation.server)!, path: "v2/connect", token: token,
                identity: identity, server: false, accepts: { DeviceIdentity.fingerprint($0) == invitation.fingerprint })
            try await until { closed }
            wire.close()
            XCTAssertFalse(leaked, command); XCTAssertTrue(host.relay.clients.isEmpty, command)
            XCTAssertNil(host.relay.candidate); XCTAssertTrue(host.sessions.isEmpty)
        }
    }
    private func rejectedBeforeAuthorization(host: HostController, invitation: SecureInvitation, wrongContext: Bool, legacy: Bool = false) async throws {
        let token = try SecretStore.randomToken(), id = UUID().uuidString
        let api = RelayClient(), identity = try DeviceIdentity.create()
        let _: HostIdentity = try await api.request(URL(string: invitation.server)!, path: "v2/clients", body: ["id": id, "token": token, "code": invitation.code, "name": "Rejected test"])
        let wire = SecureTransport(); defer { wire.close() }
        var closed = false, accepted = false
        wire.onClose = { closed = true }
        wire.onPacket = { if $0.type == "welcome" { accepted = true } }
        wire.onReady = { _ in
            if wrongContext || legacy {
                var packet = SecurePacket(type: "hello")
                packet.server = legacy ? invitation.server : "https://different-origin.invalid"; packet.hostID = invitation.hostID
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
