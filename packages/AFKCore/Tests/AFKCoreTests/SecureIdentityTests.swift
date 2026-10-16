import XCTest
import NIOSSL
@testable import AFKCore

@MainActor final class SecureIdentityTests: XCTestCase {
    private let host = HostIdentity(id: UUID().uuidString, code: "ABCDEFGH", name: "Mac")
    func testIdentitySurvivesSerialization() throws {
        let identity = try DeviceIdentity.create()
        let restored = try JSONDecoder().decode(DeviceIdentity.self, from: JSONEncoder().encode(identity))
        XCTAssertEqual(identity.fingerprint, restored.fingerprint)
        XCTAssertNotEqual(identity.fingerprint, try DeviceIdentity.create().fingerprint)
        _ = try NIOSSLContext(configuration: restored.tlsConfiguration(server: true))
    }
    func testInvitationValidationAndOrigin() throws {
        let trust = HostTrustStore(state: HostTrustState(identity: try DeviceIdentity.create()), save: { _ in })
        let now = Date()
        let invite = try trust.invitation(server: "https://EXAMPLE.com:443/", host: host, now: now)
        XCTAssertEqual(invite.server, "https://example.com")
        XCTAssertEqual(try SecureInvitation.decode(invite.encoded(), now: now).fingerprint, trust.state.identity.fingerprint)
        XCTAssertThrowsError(try SecureInvitation.decode(invite.encoded(), now: now.addingTimeInterval(301)))
        XCTAssertThrowsError(try SecureInvitation.decode("AFK2:invalid"))
        XCTAssertThrowsError(try canonicalServer("http://example.com"))
        XCTAssertThrowsError(try canonicalServer("https://user:secret@example.com"))
        XCTAssertThrowsError(try canonicalServer("https://example.com/?token=secret"))
    }
    func testSingleUseReconnectAndCertificateSubstitution() throws {
        var persisted: HostTrustState?
        let trust = HostTrustStore(state: HostTrustState(identity: try DeviceIdentity.create()), save: { persisted = $0 })
        let invite = try trust.invitation(server: "https://example.com", host: host)
        let peer = try DeviceIdentity.create(); let id = UUID().uuidString
        try trust.authorize(id: id, name: "Phone", certificate: peer.certificate, invitationID: invite.id, secret: invite.secret)
        XCTAssertNil(persisted?.pending)
        let restored = HostTrustStore(state: try XCTUnwrap(persisted), save: { persisted = $0 })
        // An acknowledgement lost after commit can recover with the same identity.
        try restored.authorize(id: id, name: "Phone", certificate: peer.certificate, invitationID: invite.id, secret: invite.secret)
        XCTAssertThrowsError(try restored.authorize(id: UUID().uuidString, name: "Other", certificate: peer.certificate, invitationID: invite.id, secret: invite.secret))
        XCTAssertThrowsError(try restored.authorize(id: id, name: "Other", certificate: DeviceIdentity.create().certificate, invitationID: nil, secret: nil))
        try restored.revoke(id)
        let revoked = HostTrustStore(state: try XCTUnwrap(persisted), save: { _ in })
        XCTAssertThrowsError(try revoked.authorize(id: id, name: "Phone", certificate: peer.certificate, invitationID: invite.id, secret: invite.secret))
    }
    func testFailedPersistenceNeverAuthorizesOrConsumesInvitation() throws {
        var fail = false
        let trust = HostTrustStore(state: HostTrustState(identity: try DeviceIdentity.create()), save: { _ in if fail { throw SecureError.persistence } })
        let invite = try trust.invitation(server: "https://example.com", host: host)
        fail = true
        XCTAssertThrowsError(try trust.authorize(id: UUID().uuidString, name: "Phone", certificate: DeviceIdentity.create().certificate, invitationID: invite.id, secret: invite.secret))
        XCTAssertTrue(trust.state.peers.isEmpty); XCTAssertNotNil(trust.state.pending)
        XCTAssertThrowsError(try trust.invitation(server: "https://example.com", host: host))
        XCTAssertEqual(trust.state.pending?.id, invite.id)
    }
    func testAttemptsPersistAndExpire() throws {
        var persisted: HostTrustState?
        var trust = HostTrustStore(state: HostTrustState(identity: try DeviceIdentity.create()), save: { persisted = $0 })
        let invite = try trust.invitation(server: "https://example.com", host: host)
        let peer = try DeviceIdentity.create()
        for _ in 0..<5 {
            XCTAssertThrowsError(try trust.authorize(id: UUID().uuidString, name: "Phone", certificate: peer.certificate, invitationID: invite.id, secret: "wrong"))
            trust = HostTrustStore(state: try XCTUnwrap(persisted), save: { persisted = $0 })
        }
        XCTAssertThrowsError(try trust.authorize(id: UUID().uuidString, name: "Phone", certificate: peer.certificate, invitationID: invite.id, secret: invite.secret))
        let fresh = try trust.invitation(server: "https://example.com", host: host)
        XCTAssertThrowsError(try trust.authorize(id: UUID().uuidString, name: "Phone", certificate: peer.certificate, invitationID: fresh.id, secret: fresh.secret, now: fresh.expires))
    }
    func testRevocationPersistenceFailureKeepsStateConsistent() throws {
        var fail = false
        let trust = HostTrustStore(state: HostTrustState(identity: try DeviceIdentity.create()), save: { _ in if fail { throw SecureError.persistence } })
        let invite = try trust.invitation(server: "https://example.com", host: host), peer = try DeviceIdentity.create(), id = UUID().uuidString
        try trust.authorize(id: id, name: "Phone", certificate: peer.certificate, invitationID: invite.id, secret: invite.secret)
        fail = true
        XCTAssertThrowsError(try trust.revoke(id)); XCTAssertEqual(trust.state.peers.count, 1)
    }
}
