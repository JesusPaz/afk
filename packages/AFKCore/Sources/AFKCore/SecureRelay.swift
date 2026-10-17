import Foundation
import Combine

private struct ControlOffer: Decodable { let type: String; let id: String; let clientID: String }
private struct SecureHostConnection: Codable { let id: String; let token: String }

@MainActor public final class SecureHostRelay: ObservableObject {
    @Published public private(set) var connected = false
    @Published public private(set) var status = L10n.text("Sin conexión")
    public var onMessage: ((Message) -> Void)?
    public var onDisconnect: (() -> Void)?
    @Published public private(set) var candidate: PairingCandidate?
    public var onPairingEnded: (() -> Void)?
    private var pendingWelcome: SecurePacket?
    private var invitationTimeout: Task<Void, Never>?
    private let api = RelayClient()
    private let controlSession = secureURLSession()
    private var control: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var channels: [String: SecureTransport] = [:]
    private var authorized: Set<String> = []
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var generation = UUID()
    private var base: URL?
    private var credentials: SecureHostConnection?
    public private(set) var host: HostIdentity?
    public private(set) var trust: HostTrustStore?
    public init() {}
    public func connect(_ url: URL, id: String, token: String, name: String) async throws -> HostIdentity {
        disconnect(); let currentGeneration = generation
        let origin = try canonicalServer(url.absoluteString)
        let trust = try HostTrustStore(account: "host-trust-v2:\(origin):\(id)")
        let h: HostIdentity = try await api.request(url, path: "v2/hosts", body: ["id": id, "token": token, "name": name])
        guard generation == currentGeneration else { throw SecureError.disconnected }
        guard h.id == id else { throw SecureError.unauthorized }
        self.trust = trust; host = h; base = URL(string: origin)!; credentials = SecureHostConnection(id: id, token: token)
        var parts = URLComponents(string: origin + "/v2/control")!; parts.scheme = url.scheme == "https" ? "wss" : "ws"
        var request = URLRequest(url: parts.url!); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = controlSession.webSocketTask(with: request); socket.maximumMessageSize = 2048
        control = socket; socket.resume(); status = L10n.text("Conectando…")
        let current = generation
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let data: Data
                    switch try await socket.receive() {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: throw SecureError.protocolViolation
                    }
                    guard let self, self.generation == current else { return }
                    let offer = try JSONDecoder().decode(ControlOffer.self, from: data)
                    if offer.type == "ready" { self.connected = true; self.status = L10n.text("Conectado") }
                    else if offer.type == "open" { self.open(offer, generation: current) }
                    else { throw SecureError.protocolViolation }
                }
            } catch {
                guard let self, self.generation == current else { return }
                self.disconnect()
            }
        }
        return h
    }
    public func restoreTrust(_ url: URL, id: String, token: String) throws {
        guard !connected else { return }
        let origin = try canonicalServer(url.absoluteString)
        trust = try HostTrustStore(account: "host-trust-v2:\(origin):\(id)")
        base = URL(string: origin)!; credentials = SecureHostConnection(id: id, token: token)
    }
    public func invitation() throws -> Pairing {
        guard let base, let host, let trust else { throw SecureError.disconnected }
        try cancelInvitation()
        let invite = try trust.invitation(server: base.absoluteString, host: host)
        invitationTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            try? self?.cancelInvitation()
        }
        return try Pairing(secret: invite.encoded(), expiresAt: ISO8601DateFormatter().string(from: invite.expires))
    }
    public var clients: [PairedClient] { trust?.state.peers.map { PairedClient(id: $0.id, name: $0.name) } ?? [] }
    public func revoke(_ id: String) async throws {
        guard let trust else { throw SecureError.disconnected }
        try cancelInvitation()
        do { try trust.revoke(id) } catch { disconnect(); throw error }
        drop(id)
        if let base, let credentials { try await api.revoke(base, token: credentials.token, clientID: id, version: "v2") }
    }
    public func expireInvitationIfNeeded() throws {
        if let pending = trust?.state.pending, pending.expires <= Date() { try cancelInvitation() }
    }
    public func cancelInvitation() throws {
        let id = candidate?.clientID
        candidate = nil; pendingWelcome = nil; invitationTimeout?.cancel(); invitationTimeout = nil
        onPairingEnded?()
        if let id { drop(id) }
        do { try trust?.cancelInvitation() } catch { disconnect(); throw error }
    }
    public func approvePairing(_ id: UUID) throws {
        guard let candidate, candidate.id == id, let welcome = pendingWelcome,
              let transport = channels[candidate.clientID], let trust else { throw SecureError.unauthorized }
        do { try trust.confirm(id) } catch { try? cancelInvitation(); throw error }
        self.candidate = nil; pendingWelcome = nil; invitationTimeout?.cancel(); invitationTimeout = nil
        onPairingEnded?()
        finishAuthorization(candidate.clientID, welcome: welcome, transport: transport)
    }
    private func finishAuthorization(_ id: String, welcome: SecurePacket, transport: SecureTransport) {
        authorized.insert(id); timeouts.removeValue(forKey: id)?.cancel()
        transport.send(welcome)
        var m = Message("clientConnected"); m.clientID = id; onMessage?(m)
    }
    public func revokeAll() throws {
        disconnect()
        try trust?.revokeAll()
    }
    private func open(_ offer: ControlOffer, generation current: UUID) {
        guard offer.id.count == 32, offer.id.allSatisfy(\.isHexDigit), UUID(uuidString: offer.clientID) != nil,
              let base, let credentials, let trust, let host else { return }
        if channels[offer.clientID] != nil { return }
        guard channels.count < 8 else { return }
        let transport = SecureTransport(); channels[offer.clientID] = transport
        let helloDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        var certificate: Data?
        transport.onReady = { certificate = $0 }
        transport.onClose = { [weak self, weak transport] in
            guard let self, self.channels[offer.clientID] === transport else { return }; self.drop(offer.clientID)
        }
        transport.onPacket = { [weak self, weak transport] packet in
            guard let self, let transport, self.generation == current, self.channels[offer.clientID] === transport else { return }
            do {
                guard packet.version == 2 else { throw SecureError.protocolViolation }
                if !self.authorized.contains(offer.clientID) {
                    guard ContinuousClock.now < helloDeadline, packet.message == nil, (try JSONEncoder().encode(packet)).count <= 2048,
                          packet.type == "hello", packet.server == base.absoluteString, packet.hostID == host.id,
                          packet.clientID == offer.clientID, let nonce = packet.nonce, nonce.count == 43,
                          let certificate else { throw SecureError.unauthorized }

                    var welcome = SecurePacket(type: "welcome")
                    welcome.server = base.absoluteString; welcome.hostID = host.id; welcome.clientID = offer.clientID
                    welcome.nonce = nonce; welcome.fingerprint = DeviceIdentity.fingerprint(certificate)
                    if trust.state.peers.contains(where: { $0.id == offer.clientID }) {
                        try trust.authorizeExisting(id: offer.clientID, certificate: certificate)
                        self.finishAuthorization(offer.clientID, welcome: welcome, transport: transport)
                    } else {
                        guard packet.ceremony == 3 else { throw SecureError.unauthorized }
                        let reservation = try trust.reserve(id: offer.clientID, name: packet.name ?? "iPhone",
                            certificate: certificate, invitationID: packet.invitationID, secret: packet.secret)
                        let hostNonce = try SecretStore.randomToken()
                        let digest = PairingTranscript.digest(server: base.absoluteString, hostID: host.id,
                            clientID: offer.clientID, invitationID: packet.invitationID!,
                            hostFingerprint: trust.state.identity.fingerprint, clientFingerprint: DeviceIdentity.fingerprint(certificate),
                            clientNonce: nonce, hostNonce: hostNonce)
                        welcome.ceremony = 3; welcome.approvalID = reservation.uuidString
                        self.pendingWelcome = welcome
                        self.candidate = PairingCandidate(id: reservation, clientID: offer.clientID, code: PairingTranscript.code(digest))
                        self.onPairingEnded?()
                        var challenge = welcome; challenge.type = "approvalRequired"; challenge.hostNonce = hostNonce
                        transport.send(challenge)
                        self.timeouts.removeValue(forKey: offer.clientID)?.cancel()
                        let seconds = min(120, trust.state.pending!.expires.timeIntervalSinceNow)
                        self.timeouts[offer.clientID] = Task { [weak self, weak transport] in
                            try? await Task.sleep(for: .seconds(max(0, seconds)))
                            guard !Task.isCancelled, let self, self.channels[offer.clientID] === transport else { return }
                            self.drop(offer.clientID)
                        }
                    }
                } else {
                    guard trust.state.peers.contains(where: { $0.id == offer.clientID && $0.certificate == certificate }),
                          packet.type == "message", var m = packet.message,
                          ["list", "create", "attach", "claim", "release", "renew", "input", "resize", "terminate"].contains(m.type) else { throw SecureError.protocolViolation }
                    m.clientID = offer.clientID; self.onMessage?(m)
                }
            } catch {
                if trust.enrollmentDisabled { try? self.cancelInvitation() }
                self.drop(offer.clientID)
            }
        }
        timeouts[offer.clientID] = Task { [weak self, weak transport] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.channels[offer.clientID] === transport else { return }; self.drop(offer.clientID)
        }
        // This TLS admission snapshot only permits a handshake. Authorization is checked
        // again against the live, persistent trust store before any application command.
        let peers = trust.state.peers.map(\.certificate)
        let enrollment = !trust.enrollmentDisabled && (trust.state.pending.map { $0.expires > Date() && $0.attempts < 5 } ?? false)
        Task { [weak self, weak transport] in
            guard let transport else { return }
            do { try await transport.connect(base: base, path: "v2/accept/\(offer.id)", token: credentials.token, identity: trust.state.identity, server: true, accepts: { enrollment || peers.contains($0) }) }
            catch { if let self, self.channels[offer.clientID] === transport { self.drop(offer.clientID) } }
        }
    }
    private func drop(_ id: String) {
        if candidate?.clientID == id {
            candidate = nil; pendingWelcome = nil
            invitationTimeout?.cancel(); invitationTimeout = nil; onPairingEnded?()
            do { try trust?.cancelInvitation() } catch { disconnect() }
        }
        channels.removeValue(forKey: id)?.close(); timeouts.removeValue(forKey: id)?.cancel()
        if authorized.remove(id) != nil { var m = Message("clientDisconnected"); m.clientID = id; onMessage?(m) }
    }
    public func send(_ m: Message) {
        var p = SecurePacket(type: "message"); p.message = m
        for id in authorized where m.clientID == nil || m.clientID == id { channels[id]?.send(p) }
    }
    public func disconnect() {
        invitationTimeout?.cancel(); invitationTimeout = nil
        candidate = nil; pendingWelcome = nil; onPairingEnded?()
        try? trust?.cancelInvitation()
        generation = UUID(); receiver?.cancel(); receiver = nil; control?.cancel(with: .goingAway, reason: nil); control = nil
        for id in Array(channels.keys) { drop(id) }
        connected = false; status = L10n.text("Sin conexión"); onDisconnect?()
    }
}

public struct SecurePhoneConnection: Codable {
    public let server: String
    public let credentials: ClientCredentials
    public let identity: DeviceIdentity
    public let hostFingerprint: String
    var invitation: SecureInvitation?
}

@MainActor public final class SecurePhoneRelay: ObservableObject {
    @Published public private(set) var status = L10n.text("Sin conexión")
    public var onMessage: ((Message) -> Void)?
    public var onDisconnect: (() -> Void)?
    private var transport: SecureTransport?
    @Published public private(set) var comparisonCode: String?
    private var authorized = false
    private var generation = UUID()
    private var timeout: Task<Void, Never>?
    private let api = RelayClient()
    private let account: String
    private let persist: (SecurePhoneConnection) throws -> Void
    private var connectionError: Error?
    public private(set) var saved: SecurePhoneConnection?
    public init(account: String = "secure-phone-v2") {
        self.account = account; self.persist = { try SecretStore.write($0, account: account) }
    }
    init(account: String, persist: @escaping (SecurePhoneConnection) throws -> Void) {
        self.account = account; self.persist = persist
    }
    public func restore() throws -> SecurePhoneConnection? { saved = try SecretStore.read(account); return saved }
    public func pair(invitation text: String, name: String = "iPhone") async throws -> SecurePhoneConnection {
        disconnect(); connectionError = nil; let pairingGeneration = generation
        let invite = try SecureInvitation.decode(text)
        let id = UUID().uuidString, token = try SecretStore.randomToken()
        let identity = try DeviceIdentity.create()
        let host: HostIdentity = try await api.request(URL(string: invite.server)!, path: "v2/clients", body: ["id": id, "token": token, "code": invite.code, "name": name])
        guard generation == pairingGeneration else { throw SecureError.disconnected }
        guard host.id == invite.hostID, host.code == invite.code else { throw SecureError.unauthorized }
        let next = SecurePhoneConnection(server: invite.server, credentials: ClientCredentials(clientID: id, token: token, host: host), identity: identity, hostFingerprint: invite.fingerprint, invitation: invite)
        connect(using: next); let connectionGeneration = generation
        do {
            for _ in 0..<2800 {
                try Task.checkCancellation()
                guard generation == connectionGeneration else { throw connectionError ?? SecureError.disconnected }
                if authorized { return self.saved! }
                guard transport != nil else { throw SecureError.unauthorized }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw SecureError.disconnected
        } catch {
            if generation == connectionGeneration { disconnect() }
            throw error
        }
    }

    public func connect() {
        guard let saved else { return }
        connect(using: saved)
    }
    private func connect(using saved: SecurePhoneConnection) {
        disconnect()
        var approvalID: String?
        let clock = ContinuousClock()
        let invitationDeadline = clock.now.advanced(by: .seconds(max(0, saved.invitation?.expires.timeIntervalSinceNow ?? 15)))
        var phaseDeadline = min(invitationDeadline, clock.now.advanced(by: .seconds(15)))
        let transport = SecureTransport(); self.transport = transport
        status = L10n.text("Conectando…")
        let nonce: String
        do { nonce = try SecretStore.randomToken() } catch { disconnect(); return }
        transport.onReady = { [weak self, weak transport] _ in
            guard let self, let transport, self.transport === transport else { return }
            var hello = SecurePacket(type: "hello"); hello.server = saved.server; hello.hostID = saved.credentials.host.id
            hello.clientID = saved.credentials.clientID; hello.nonce = nonce; hello.name = "iPhone"
            hello.ceremony = saved.invitation == nil ? nil : 3
            hello.invitationID = saved.invitation?.id; hello.secret = saved.invitation?.secret
            transport.send(hello)
        }
        transport.onPacket = { [weak self, weak transport] packet in
            guard let self, let transport, self.transport === transport else { return }
            do {
                guard packet.version == 2 else { throw SecureError.protocolViolation }
                if !self.authorized {
                    guard clock.now < phaseDeadline else { throw SecureError.unauthorized }
                    guard packet.server == saved.server, packet.hostID == saved.credentials.host.id,
                          packet.clientID == saved.credentials.clientID, packet.nonce == nonce,
                          packet.fingerprint == saved.identity.fingerprint else { throw SecureError.unauthorized }
                    if let invite = saved.invitation {
                        guard packet.ceremony == 3, let identifier = packet.approvalID, UUID(uuidString: identifier) != nil,
                              invite.expires > Date() else { throw SecureError.unauthorized }
                        if packet.type == "approvalRequired" {
                            guard approvalID == nil, let hostNonce = packet.hostNonce, hostNonce.count == 43 else { throw SecureError.protocolViolation }
                            approvalID = identifier
                            phaseDeadline = min(invitationDeadline, clock.now.advanced(by: .seconds(120)))
                            self.comparisonCode = PairingTranscript.code(PairingTranscript.digest(server: saved.server,
                                hostID: saved.credentials.host.id, clientID: saved.credentials.clientID, invitationID: invite.id,
                                hostFingerprint: saved.hostFingerprint, clientFingerprint: saved.identity.fingerprint,
                                clientNonce: nonce, hostNonce: hostNonce))
                            self.timeout?.cancel()
                            self.timeout = Task { [weak self, weak transport] in
                                try? await Task.sleep(for: .seconds(max(0, min(120, invite.expires.timeIntervalSinceNow))))
                                guard !Task.isCancelled, let self, self.transport === transport else { return }; self.disconnect()
                            }
                            return
                        }
                        guard approvalID == identifier else { throw SecureError.unauthorized }
                    }
                    guard packet.type == "welcome" else { throw SecureError.protocolViolation }
                    var next = saved; next.invitation = nil
                    try self.persist(next); self.saved = next
                    self.comparisonCode = nil; self.authorized = true; self.timeout?.cancel(); self.status = L10n.text("Conectado")
                    self.onMessage?(Message("welcome")); self.onMessage?(Message("hostOnline"))
                } else {
                    guard packet.type == "message", let m = packet.message else { throw SecureError.protocolViolation }
                    self.onMessage?(m)
                }
            } catch { self.connectionError = error; self.disconnect() }
        }
        transport.onClose = { [weak self, weak transport] in guard let self, self.transport === transport else { return }; self.disconnect() }
        timeout = Task { [weak self, weak transport] in
            try? await Task.sleep(for: .seconds(15)); guard !Task.isCancelled, let self, self.transport === transport else { return }; self.disconnect()
        }
        Task { [weak self, weak transport] in
            guard let transport else { return }
            do { try await transport.connect(base: URL(string: saved.server)!, path: "v2/connect", token: saved.credentials.token, identity: saved.identity, server: false, accepts: { DeviceIdentity.fingerprint($0) == saved.hostFingerprint }) }
            catch { if let self, self.transport === transport { self.disconnect() } }
        }
    }
    public func send(_ m: Message) { guard authorized else { return }; var p = SecurePacket(type: "message"); p.message = m; transport?.send(p) }
    public func disconnect() {
        generation = UUID(); comparisonCode = nil; let closing = transport; transport = nil; closing?.close(); timeout?.cancel(); timeout = nil; authorized = false
        status = L10n.text("Sin conexión"); onDisconnect?()
    }
}
