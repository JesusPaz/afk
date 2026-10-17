import Foundation
import CryptoKit
import NIOSSL
import NIOCore
import X509
import Security
import LocalAuthentication

public struct DeviceIdentity: Codable {
    public let certificate: Data
    private let privateKey: String?
    private let enclaveKey: Data?
    public let requiresBiometry: Bool?
    public var isHardwareBacked: Bool { enclaveKey != nil && privateKey == nil }
    public var fingerprint: String { Self.fingerprint(certificate) }
    static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    // Software identities are retained for legacy decoding and explicit test fixtures only.
    static func create(now: Date = Date()) throws -> Self {
        let key = P256.Signing.PrivateKey()
        let signingKey = Certificate.PrivateKey(key)
        return try makeCertificate(signingKey, privateKey: key.pemRepresentation, enclaveKey: nil, biometry: false, now: now)
    }
    public static func createSecureEnclave(requireBiometry: Bool = false, context: LAContext = LAContext(), now: Date = Date()) throws -> Self {
        guard SecureEnclave.isAvailable else { throw SecureError.hardwareUnavailable }
        var error: Unmanaged<CFError>?
        let flags: SecAccessControlCreateFlags = requireBiometry ? [.privateKeyUsage, .biometryCurrentSet] : [.privateKeyUsage]
        guard let access = SecAccessControlCreateWithFlags(nil,
            requireBiometry ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            flags, &error) else { throw error!.takeRetainedValue() }
        if requireBiometry {
            var reason: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &reason) else { throw SecureError.biometryUnavailable }
        }
        context.localizedReason = L10n.text("Confirma tu identidad para autorizar el acceso a la terminal del Mac.")
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: context)
        return try makeCertificate(Certificate.PrivateKey(key), privateKey: nil, enclaveKey: key.dataRepresentation, biometry: requireBiometry, now: now)
    }
    private static func makeCertificate(_ signingKey: Certificate.PrivateKey, privateKey: String?, enclaveKey: Data?, biometry: Bool, now: Date) throws -> Self {
        let name = try DistinguishedName { CommonName("AFK device") }
        let cert = try Certificate(version: .v3, serialNumber: .init(), publicKey: signingKey.publicKey,
            notValidBefore: now.addingTimeInterval(-300), notValidAfter: now.addingTimeInterval(5 * 365 * 86400),
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {}, issuerPrivateKey: signingKey)
        let pem = try cert.serializeAsPEM().pemString
        let der = try NIOSSLCertificate(bytes: Array(pem.utf8), format: .pem).toDERBytes()
        return Self(certificate: Data(der), privateKey: privateKey, enclaveKey: enclaveKey, requiresBiometry: biometry)
    }
    func tlsConfiguration(server: Bool, authenticationContext: LAContext = LAContext()) throws -> TLSConfiguration {
        let cert = try NIOSSLCertificate(bytes: Array(certificate), format: .der)
        let key: NIOSSLPrivateKey
        if let enclaveKey, privateKey == nil {
            key = NIOSSLPrivateKey(customPrivateKey: EnclaveTLSKey(blob: enclaveKey, context: authenticationContext))
        } else if let privateKey, enclaveKey == nil {
            key = try NIOSSLPrivateKey(bytes: Array(privateKey.utf8), format: .pem)
        } else { throw SecureError.unauthorized }
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
        guard value.hasPrefix("AFK3:"), let data = Data(base64Encoded: String(value.dropFirst(5))) else { throw SecureError.invalidInvitation }
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
    case obsoleteInvitation, invalidInvitation, unauthorized, persistence, protocolViolation, disconnected, hardwareUnavailable, biometryUnavailable
    public var errorDescription: String? {
        switch self {
        case .hardwareUnavailable: return L10n.text("Este dispositivo necesita Secure Enclave para crear una identidad protegida.")
        case .biometryUnavailable: return L10n.text("Activa Face ID o Touch ID para entrar. Si cambias la biometría, vuelve a vincular el dispositivo.")
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
    public var biometricIdentity: Bool? = nil
    public var fullAccess: Bool? = nil
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
        let state = try SecretStore.read(account) ?? HostTrustState(identity: DeviceIdentity.createSecureEnclave())
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
    // Reconnection requires an already trusted exact certificate.
    public func authorizeExisting(id: String, certificate: Data) throws {
        guard state.peers.contains(where: { $0.id == id && $0.certificate == certificate }) else { throw SecureError.unauthorized }
    }
    public func reserve(id: String, name: String, certificate: Data, invitationID: String?, secret: String?, biometricIdentity: Bool = false, now: Date = Date()) throws -> UUID {
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
        reservation = (token, TrustedDevice(id: id, name: name, certificate: certificate, biometricIdentity: biometricIdentity), pending.id,
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
    public func setFullAccess(_ id: String, enabled: Bool) throws {
        guard let index = state.peers.firstIndex(where: { $0.id == id }),
              !enabled || (state.identity.isHardwareBacked && state.peers[index].biometricIdentity == true) else { throw SecureError.unauthorized }
        var next = state; next.peers[index].fullAccess = enabled
        try save(next); state = next
    }
    public func clearFullAccess() throws {
        var next = state
        for i in next.peers.indices { next.peers[i].fullAccess = false }
        try save(next); state = next
    }
    public func upgradeIdentity() throws {
        guard !state.identity.isHardwareBacked else { return }
        try cancelInvitation()
        let next = try HostTrustState(identity: DeviceIdentity.createSecureEnclave())
        try save(next); state = next
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
