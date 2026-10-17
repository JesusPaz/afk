import Foundation
import CryptoKit
import NIOSSL
import NIOCore
import X509

public struct DeviceIdentity: Codable {
    public let certificate: Data
    private let privateKey: String
    public var fingerprint: String { Self.fingerprint(certificate) }
    static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func create(now: Date = Date()) throws -> Self {
        let key = P256.Signing.PrivateKey()
        let signingKey = Certificate.PrivateKey(key)
        let name = try DistinguishedName { CommonName("AFK device") }
        let cert = try Certificate(version: .v3, serialNumber: .init(), publicKey: signingKey.publicKey,
            notValidBefore: now.addingTimeInterval(-300), notValidAfter: now.addingTimeInterval(5 * 365 * 86400),
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {}, issuerPrivateKey: signingKey)
        let pem = try cert.serializeAsPEM().pemString
        let der = try NIOSSLCertificate(bytes: Array(pem.utf8), format: .pem).toDERBytes()
        return Self(certificate: Data(der), privateKey: key.pemRepresentation)
    }
    func tlsConfiguration(server: Bool) throws -> TLSConfiguration {
        let cert = try NIOSSLCertificate(bytes: Array(certificate), format: .der)
        let key = try NIOSSLPrivateKey(bytes: Array(privateKey.utf8), format: .pem)
        var c = server ? TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate(cert)], privateKey: .privateKey(key)) : TLSConfiguration.makeClientConfiguration()
        c.certificateChain = [.certificate(cert)]; c.privateKey = .privateKey(key)
        c.minimumTLSVersion = .tlsv13; c.maximumTLSVersion = .tlsv13
        c.certificateVerification = .noHostnameVerification
        c.applicationProtocols = ["afk-e2ee/2"]
        return c
    }
}

public struct SecureInvitation: Codable {
    public let version: Int
    public let server: String
    public let hostID: String
    public let code: String
    public let fingerprint: String
    public let id: String
    public let secret: String
    public let expires: Date
    public func encoded() throws -> String { "AFK3:" + (try JSONEncoder().encode(self)).base64EncodedString() }
    public static func decode(_ value: String, now: Date = Date()) throws -> Self {
        guard value.utf8.count <= 2048 else { throw SecureError.invalidInvitation }
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("AFK2:") { throw SecureError.obsoleteInvitation }
        guard value.utf8.count <= 2048, value.hasPrefix("AFK3:"), let data = Data(base64Encoded: String(value.dropFirst(5))) else { throw SecureError.invalidInvitation }
        let invite = try JSONDecoder().decode(Self.self, from: data)
        guard invite.version == 3, invite.expires > now, invite.expires.timeIntervalSince(now) <= 310,
              UUID(uuidString: invite.hostID) != nil, UUID(uuidString: invite.id) != nil,
              invite.secret.count == 43, invite.secret.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              invite.code.utf8.count <= 16, !invite.code.isEmpty, invite.code.utf8.allSatisfy({ (33...126).contains($0) }), invite.server.utf8.count <= 512, invite.fingerprint.count == 64,
              invite.fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              try canonicalServer(invite.server) == invite.server else { throw SecureError.invalidInvitation }
        return invite
    }
}

public enum SecureError: Error, LocalizedError {
    case obsoleteInvitation, invalidInvitation, unauthorized, persistence, protocolViolation, disconnected
    public var errorDescription: String? {
        switch self {
        case .obsoleteInvitation: return L10n.text("Actualiza ambas apps y genera una invitación nueva en el Mac.")
        case .invalidInvitation: return L10n.text("La invitación segura no es válida o venció. Crea otra en el Mac.")
        case .unauthorized: return L10n.text("No se pudo verificar la identidad del dispositivo.")
        case .persistence: return L10n.text("No se pudo guardar la autorización.")
        case .protocolViolation: return L10n.text("La conexión segura no cumple el protocolo.")
        case .disconnected: return L10n.text("Se cerró la conexión segura. Reconecta para continuar.")
        }
    }
}
public func canonicalServer(_ value: String) throws -> String {
    let url = try ServerAddress.parse(value)
    var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    parts.host = parts.host?.lowercased(); parts.path = ""
    if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
    return parts.string!
}

public struct TrustedDevice: Codable {
    public let id: String
    public let name: String
    public let certificate: Data
}
struct PendingInvitation: Codable {
    let id: String
    let hash: String
    let expires: Date
    var attempts: Int
}
public struct HostTrustState: Codable {
    public let identity: DeviceIdentity
    public internal(set) var peers: [TrustedDevice] = []
    var pending: PendingInvitation?
    public init(identity: DeviceIdentity) { self.identity = identity }
}

// Persist the entire authorization transaction before exposing its result to either peer.
@MainActor public final class HostTrustStore {
    public private(set) var state: HostTrustState
    public private(set) var enrollmentDisabled = false
    private var reservation: (token: UUID, peer: TrustedDevice, invitation: String, deadline: TimeInterval)?
    private var invitationDeadline: TimeInterval?
    private let uptime: () -> TimeInterval
    private let save: (HostTrustState) throws -> Void
    public init(state: HostTrustState, save: @escaping (HostTrustState) throws -> Void, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.state = state; self.save = save; self.uptime = uptime }
    public convenience init(account: String) throws {
        let state = try SecretStore.read(account) ?? HostTrustState(identity: DeviceIdentity.create())
        try SecretStore.write(state, account: account)
        self.init(state: state, save: { try SecretStore.write($0, account: account) })
        try cancelInvitation()
    }
    public func invitation(server: String, host: HostIdentity, now: Date = Date()) throws -> SecureInvitation {
        try cancelInvitation()
        let invite = try SecureInvitation(version: 3, server: canonicalServer(server), hostID: host.id, code: host.code,
            fingerprint: state.identity.fingerprint, id: UUID().uuidString, secret: SecretStore.randomToken(), expires: now.addingTimeInterval(300))
        _ = try SecureInvitation.decode(invite.encoded(), now: now)
        var next = state
        next.pending = PendingInvitation(id: invite.id, hash: DeviceIdentity.fingerprint(Data(invite.secret.utf8)), expires: invite.expires, attempts: 0)
        try save(next); state = next; enrollmentDisabled = false; invitationDeadline = uptime() + 300
        return invite
    }
    // Legacy authorization is reconnection only. No invitation can bypass consent.
    public func authorize(id: String, name: String, certificate: Data, invitationID: String?, secret: String?, now: Date = Date()) throws {
        guard state.peers.contains(where: { $0.id == id && $0.certificate == certificate }) else { throw SecureError.unauthorized }
    }
    public func reserve(id: String, name: String, certificate: Data, invitationID: String?, secret: String?, now: Date = Date()) throws -> UUID {
        guard !enrollmentDisabled, var pending = state.pending, pending.expires > now,
              let deadline = invitationDeadline, uptime() < deadline,
              pending.attempts < 5, state.peers.count < 16 else { throw SecureError.unauthorized }
        pending.attempts += 1
        var next = state; next.pending = pending
        do { try save(next); state = next } catch { enrollmentDisabled = true; reservation = nil; throw error }
        guard reservation == nil, UUID(uuidString: id) != nil, name.utf8.count <= 80,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !state.peers.contains(where: { $0.id == id }),
              invitationID == pending.id, let secret, secret.count == 43,
              DeviceIdentity.fingerprint(Data(secret.utf8)) == pending.hash else { throw SecureError.unauthorized }
        let token = UUID()
        reservation = (token, TrustedDevice(id: id, name: name, certificate: certificate), pending.id,
                       min(deadline, uptime() + min(120, pending.expires.timeIntervalSince(now))))
        return token
    }
    public func confirm(_ token: UUID, now: Date = Date()) throws {
        guard !enrollmentDisabled, let candidate = reservation, candidate.token == token,
              let pending = state.pending, pending.id == candidate.invitation,
              pending.expires > now, uptime() < candidate.deadline else { throw SecureError.unauthorized }
        var next = state; next.peers.append(candidate.peer); next.pending = nil
        do { try save(next) } catch { enrollmentDisabled = true; reservation = nil; throw error }
        state = next; reservation = nil; invitationDeadline = nil
    }
    public func cancelInvitation() throws {
        reservation = nil; invitationDeadline = nil
        var next = state; next.pending = nil
        do { try save(next); state = next } catch { enrollmentDisabled = true; throw error }
    }
    public func revokeAll() throws {
        try cancelInvitation()
        var next = state; next.peers = []; next.pending = nil; try save(next); state = next
    }
    public func revoke(_ id: String) throws {
        try cancelInvitation()
        var next = state; next.peers.removeAll { $0.id == id }; next.pending = nil
        try save(next); state = next
    }
}

// TLS proves possession of the device key; this callback defines direct identity trust.
// It deliberately grants no CA delegation and does not use DNS for device identities.
enum DeviceTLS {
    static let applicationProtocol = "afk-e2ee/2"
    static func handler(context: NIOSSLContext, server: Bool, accepts: @escaping (Data) -> Bool,
                        verified: @escaping (Data) -> Void = { _ in }) throws -> ChannelHandler {
        let verify: NIOSSLCustomVerificationCallback = { chain, promise in
            let now = Int(Date().timeIntervalSince1970)
            guard chain.count == 1, let cert = chain.first,
                  cert.notValidBefore <= now, cert.notValidAfter > now,
                  let der = try? cert.toDERBytes(), accepts(Data(der)) else { promise.succeed(.failed); return }
            verified(Data(der)); promise.succeed(.certificateVerified)
        }
        if server { return NIOSSLServerHandler(context: context, customVerificationCallback: verify) }
        return try NIOSSLClientHandler(context: context, serverHostname: nil, customVerificationCallback: verify)
    }
}
