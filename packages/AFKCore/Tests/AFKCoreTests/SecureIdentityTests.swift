import XCTest
import NIOSSL
import CoreImage
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
        try trust.confirm(trust.reserve(id: id, name: "Phone", certificate: peer.certificate, invitationID: invite.id, secret: invite.secret))
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
        XCTAssertThrowsError(try trust.reserve(id: UUID().uuidString, name: "Phone", certificate: DeviceIdentity.create().certificate, invitationID: invite.id, secret: invite.secret))
        XCTAssertTrue(trust.state.peers.isEmpty); XCTAssertNotNil(trust.state.pending)
        XCTAssertThrowsError(try trust.invitation(server: "https://example.com", host: host))
        XCTAssertEqual(trust.state.pending?.id, invite.id)
    }
    func testAttemptsPersistAndExpire() throws {
        var persisted: HostTrustState?
        let trust = HostTrustStore(state: HostTrustState(identity: try DeviceIdentity.create()), save: { persisted = $0 })
        let invite = try trust.invitation(server: "https://example.com", host: host)
        let peer = try DeviceIdentity.create()
        for _ in 0..<5 {
            XCTAssertThrowsError(try trust.reserve(id: UUID().uuidString, name: "Phone", certificate: peer.certificate, invitationID: invite.id, secret: "wrong"))
            XCTAssertEqual(persisted?.pending?.attempts, trust.state.pending?.attempts)
        }
        XCTAssertThrowsError(try trust.reserve(id: UUID().uuidString, name: "Phone", certificate: peer.certificate, invitationID: invite.id, secret: invite.secret))
        let fresh = try trust.invitation(server: "https://example.com", host: host)
        XCTAssertThrowsError(try trust.reserve(id: UUID().uuidString, name: "Phone", certificate: peer.certificate, invitationID: fresh.id, secret: fresh.secret, now: fresh.expires))
    }
    func testStopInvalidatesInvitationAndRevokeAllPersistsAtomically() throws {
        var saved: HostTrustState?
        var fail = false
        let trust = HostTrustStore(state: HostTrustState(identity: try DeviceIdentity.create()), save: {
            if fail { throw SecureError.persistence }; saved = $0
        })
        let invite = try trust.invitation(server: "https://example.com", host: host)
        try trust.cancelInvitation()
        XCTAssertNil(saved?.pending)
        XCTAssertThrowsError(try trust.reserve(id: UUID().uuidString, name: "Phone", certificate: DeviceIdentity.create().certificate, invitationID: invite.id, secret: invite.secret))
        let next = try trust.invitation(server: "https://example.com", host: host)
        let id = UUID().uuidString, peer = try DeviceIdentity.create()
        try trust.confirm(trust.reserve(id: id, name: "Phone", certificate: peer.certificate, invitationID: next.id, secret: next.secret))
        fail = true
        XCTAssertThrowsError(try trust.revokeAll()); XCTAssertEqual(trust.state.peers.count, 1)
        fail = false; try trust.revokeAll()
        let restored = HostTrustStore(state: try XCTUnwrap(saved), save: { _ in })
        XCTAssertTrue(restored.state.peers.isEmpty)
        XCTAssertThrowsError(try restored.authorize(id: id, name: "Phone", certificate: peer.certificate, invitationID: nil, secret: nil))
    }
    func testRevocationPersistenceFailureKeepsStateConsistent() throws {
        var fail = false
        let trust = HostTrustStore(state: HostTrustState(identity: try DeviceIdentity.create()), save: { _ in if fail { throw SecureError.persistence } })
        let invite = try trust.invitation(server: "https://example.com", host: host), peer = try DeviceIdentity.create(), id = UUID().uuidString
        try trust.confirm(trust.reserve(id: id, name: "Phone", certificate: peer.certificate, invitationID: invite.id, secret: invite.secret))
        fail = true
        XCTAssertThrowsError(try trust.revoke(id)); XCTAssertEqual(trust.state.peers.count, 1)
    }
}

@MainActor final class PairingConsentTests: XCTestCase {
    private let host = HostIdentity(id: "11111111-1111-1111-1111-111111111111", code: "ABCDEFGH", name: "Mac")
    func testReservationDoesNotAuthorizeAndConcurrentAttemptCannotReplaceIt() throws {
        var persisted: HostTrustState?
        let store = HostTrustStore(state: HostTrustState(identity: try DeviceIdentity.create()), save: { persisted = $0 })
        let invite = try store.invitation(server: "https://example.com", host: host)
        let peer = try DeviceIdentity.create(), id = UUID().uuidString
        XCTAssertThrowsError(try store.authorize(id: id, name: "Phone", certificate: peer.certificate, invitationID: invite.id, secret: invite.secret))
        let token = try store.reserve(id: id, name: "Phone", certificate: peer.certificate, invitationID: invite.id, secret: invite.secret)
        XCTAssertTrue(store.state.peers.isEmpty); XCTAssertTrue(persisted!.peers.isEmpty)
        for _ in 0..<4 {
            XCTAssertThrowsError(try store.reserve(id: UUID().uuidString, name: "Other", certificate: peer.certificate, invitationID: invite.id, secret: invite.secret))
        }
        XCTAssertEqual(persisted?.pending?.attempts, 5)
        try store.confirm(token)
        XCTAssertEqual(persisted?.peers.first?.id, id); XCTAssertNil(persisted?.pending)
        XCTAssertThrowsError(try store.confirm(token))
    }
    func testLateApprovalClockRollbackReplacementCancellationAndRestart() throws {
        var uptime = 100.0
        var persisted: HostTrustState?
        let store = HostTrustStore(state: HostTrustState(identity: try DeviceIdentity.create()), save: { persisted = $0 }, uptime: { uptime })
        let peer = try DeviceIdentity.create(), now = Date()
        func reserve() throws -> UUID {
            let invite = try store.invitation(server: "https://example.com", host: host, now: now)
            return try store.reserve(id: UUID().uuidString, name: "Phone", certificate: peer.certificate, invitationID: invite.id, secret: invite.secret, now: now)
        }
        let expired = try reserve(); uptime += 121
        XCTAssertThrowsError(try store.confirm(expired, now: now.addingTimeInterval(-3600)))
        let replaced = try reserve(); let current = try reserve()
        XCTAssertThrowsError(try store.confirm(replaced, now: now))
        try store.cancelInvitation(); XCTAssertThrowsError(try store.confirm(current, now: now))
        let beforeRestart = try reserve()
        let restored = HostTrustStore(state: persisted!, save: { _ in })
        XCTAssertThrowsError(try restored.confirm(beforeRestart))
        XCTAssertTrue(store.state.peers.isEmpty)
    }
    func testFailedCommitAndInvalidationCloseEnrollment() throws {
        var fail = false
        let store = HostTrustStore(state: HostTrustState(identity: try DeviceIdentity.create()), save: { _ in if fail { throw SecureError.persistence } })
        let invite = try store.invitation(server: "https://example.com", host: host)
        let peer = try DeviceIdentity.create()
        let token = try store.reserve(id: UUID().uuidString, name: "Phone", certificate: peer.certificate, invitationID: invite.id, secret: invite.secret)
        fail = true
        XCTAssertThrowsError(try store.confirm(token)); XCTAssertTrue(store.state.peers.isEmpty)
        XCTAssertThrowsError(try store.cancelInvitation()); XCTAssertTrue(store.enrollmentDisabled)
        fail = false
        XCTAssertThrowsError(try store.confirm(token))
        XCTAssertThrowsError(try store.reserve(id: UUID().uuidString, name: "Phone", certificate: peer.certificate, invitationID: invite.id, secret: invite.secret))
        _ = try store.invitation(server: "https://example.com", host: host)
        XCTAssertFalse(store.enrollmentDisabled)
    }
    func testInvitationBoundsLegacyAndQRCapacity() throws {
        let store = HostTrustStore(state: HostTrustState(identity: try DeviceIdentity.create()), save: { _ in })
        let invitation = try store.invitation(server: "https://example.com", host: host)
        let encoded = try invitation.encoded()
        XCTAssertThrowsError(try SecureInvitation.decode(encoded.replacingOccurrences(of: "AFK3:", with: "AFK2:")))
        XCTAssertThrowsError(try SecureInvitation.decode(String(repeating: " ", count: 2049) + encoded))
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(invitation)) as? [String: Any])
        for (key, value) in [("server", "https://example.com/redirect"), ("secret", String(repeating: "!", count: 43)), ("version", 2 as Any)] {
            let original = fields[key]; fields[key] = value
            let invalid = "AFK3:" + (try JSONSerialization.data(withJSONObject: fields)).base64EncodedString()
            XCTAssertThrowsError(try SecureInvitation.decode(invalid)); fields[key] = original
        }
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        for payload in [encoded, String(repeating: "a", count: 2048)] {
            let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
            filter.setValue(Data(payload.utf8), forKey: "inputMessage"); filter.setValue("M", forKey: "inputCorrectionLevel")
            let output = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 3, y: 3))
            let white = CIImage(color: CIColor.white).cropped(to: output.extent.insetBy(dx: -24, dy: -24))
            let features = detector.features(in: output.composited(over: white))
            XCTAssertEqual((features.first as? CIQRCodeFeature)?.messageString, payload)
        }
    }
    func testTranscriptVectorAndEveryContextField() {
        let fields = ["https://example.com", "host", "client", "invitation", "host-fingerprint", "client-fingerprint", "client-nonce", "host-nonce"]
        func digest(_ f: [String]) -> Data {
            PairingTranscript.digest(server: f[0], hostID: f[1], clientID: f[2], invitationID: f[3], hostFingerprint: f[4], clientFingerprint: f[5], clientNonce: f[6], hostNonce: f[7])
        }
        let expected = digest(fields)
        XCTAssertEqual(expected.map { String(format: "%02x", $0) }.joined(), "ac188c10af11b779cccfab975e77070ba44913899f17cc85d5b867bc3db750f8")
        XCTAssertEqual(PairingTranscript.code(expected), "8728 9872")
        for index in fields.indices { var changed = fields; changed[index] += "x"; XCTAssertNotEqual(digest(changed), expected) }
    }
}
