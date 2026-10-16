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
    public func encoded() throws -> String { "AFK2:" + (try JSONEncoder().encode(self)).base64EncodedString() }
    public static func decode(_ value: String, now: Date = Date()) throws -> Self {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count < 4096, value.hasPrefix("AFK2:"), let data = Data(base64Encoded: String(value.dropFirst(5))) else { throw SecureError.invalidInvitation }
        let invite = try JSONDecoder().decode(Self.self, from: data)
        guard invite.version == 2, invite.expires > now, invite.expires.timeIntervalSince(now) <= 310,
              UUID(uuidString: invite.hostID) != nil, UUID(uuidString: invite.id) != nil,
              invite.secret.count == 43, invite.fingerprint.count == 64,
              invite.fingerprint.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              try canonicalServer(invite.server) == invite.server else { throw SecureError.invalidInvitation }
        return invite
    }
}

public enum SecureError: Error, LocalizedError {
    case invalidInvitation, unauthorized, persistence, protocolViolation, disconnected
    public var errorDescription: String? {
        switch self {
        case .invalidInvitation: return "La invitación segura no es válida o venció. Crea otra en el Mac."
        case .unauthorized: return "No se pudo verificar la identidad del dispositivo."
        case .persistence: return "No se pudo guardar la autorización."
        case .protocolViolation: return "La conexión segura no cumple el protocolo."
        case .disconnected: return "Se cerró la conexión segura. Reconecta para continuar."
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
    private let save: (HostTrustState) throws -> Void
    public init(state: HostTrustState, save: @escaping (HostTrustState) throws -> Void) { self.state = state; self.save = save }
    public convenience init(account: String) throws {
        let state = try SecretStore.read(account) ?? HostTrustState(identity: DeviceIdentity.create())
        try SecretStore.write(state, account: account)
        self.init(state: state, save: { try SecretStore.write($0, account: account) })
    }
    public func invitation(server: String, host: HostIdentity, now: Date = Date()) throws -> SecureInvitation {
        let invite = try SecureInvitation(version: 2, server: canonicalServer(server), hostID: host.id, code: host.code,
            fingerprint: state.identity.fingerprint, id: UUID().uuidString, secret: SecretStore.randomToken(), expires: now.addingTimeInterval(300))
        var next = state
        next.pending = PendingInvitation(id: invite.id, hash: DeviceIdentity.fingerprint(Data(invite.secret.utf8)), expires: invite.expires, attempts: 0)
        try save(next); state = next
        return invite
    }
    public func authorize(id: String, name: String, certificate: Data, invitationID: String?, secret: String?, now: Date = Date()) throws {
        guard UUID(uuidString: id) != nil, name.count <= 80 else { throw SecureError.unauthorized }
        if let peer = state.peers.first(where: { $0.id == id }) {
            guard peer.certificate == certificate else { throw SecureError.unauthorized }
            return
        }
        guard var pending = state.pending, pending.expires > now, pending.attempts < 5, state.peers.count < 16 else { throw SecureError.unauthorized }
        pending.attempts += 1
        var next = state; next.pending = pending
        guard invitationID == pending.id, let secret, secret.count == 43,
              DeviceIdentity.fingerprint(Data(secret.utf8)) == pending.hash else {
            try save(next); state = next; throw SecureError.unauthorized
        }
        next.peers.append(TrustedDevice(id: id, name: name, certificate: certificate)); next.pending = nil
        try save(next); state = next
    }
    public func cancelInvitation() throws {
        var next = state; next.pending = nil; try save(next); state = next
    }
    public func revokeAll() throws {
        var next = state; next.peers = []; next.pending = nil; try save(next); state = next
    }
    public func revoke(_ id: String) throws {
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
