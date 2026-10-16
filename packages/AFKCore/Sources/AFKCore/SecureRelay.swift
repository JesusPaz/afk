import Foundation
import Combine

private struct ControlOffer: Decodable { let type: String; let id: String; let clientID: String }
private struct SecureHostConnection: Codable { let id: String; let token: String }

@MainActor public final class SecureHostRelay: ObservableObject {
    @Published public private(set) var connected = false
    @Published public private(set) var status = L10n.text("Sin conexión")
    public var onMessage: ((Message) -> Void)?
    public var onDisconnect: (() -> Void)?
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
        let invite = try trust.invitation(server: base.absoluteString, host: host)
        return try Pairing(secret: invite.encoded(), expiresAt: ISO8601DateFormatter().string(from: invite.expires))
    }
    public var clients: [PairedClient] { trust?.state.peers.map { PairedClient(id: $0.id, name: $0.name) } ?? [] }
    public func revoke(_ id: String) async throws {
        guard let trust else { throw SecureError.disconnected }
        do { try trust.revoke(id) } catch { disconnect(); throw error }
        drop(id)
        if let base, let credentials { try await api.revoke(base, token: credentials.token, clientID: id, version: "v2") }
    }
    public func cancelInvitation() throws { try trust?.cancelInvitation() }
    public func revokeAll() throws {
        disconnect()
        try trust?.revokeAll()
    }
    private func open(_ offer: ControlOffer, generation current: UUID) {
        guard offer.id.count == 32, offer.id.allSatisfy(\.isHexDigit), UUID(uuidString: offer.clientID) != nil,
              let base, let credentials, let trust, let host else { return }
        if channels[offer.clientID] != nil { drop(offer.clientID) }
        guard channels.count < 8 else { return }
        let transport = SecureTransport(); channels[offer.clientID] = transport
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
                    guard packet.type == "hello", packet.server == base.absoluteString, packet.hostID == host.id,
                          packet.clientID == offer.clientID, let nonce = packet.nonce, nonce.count == 43,
                          let certificate else { throw SecureError.unauthorized }
                    try trust.authorize(id: offer.clientID, name: packet.name ?? "iPhone", certificate: certificate, invitationID: packet.invitationID, secret: packet.secret)
                    self.authorized.insert(offer.clientID); self.timeouts.removeValue(forKey: offer.clientID)?.cancel()
                    var welcome = SecurePacket(type: "welcome")
                    welcome.server = base.absoluteString; welcome.hostID = host.id; welcome.clientID = offer.clientID
                    welcome.nonce = nonce; welcome.fingerprint = DeviceIdentity.fingerprint(certificate)
                    transport.send(welcome)
                    var m = Message("clientConnected"); m.clientID = offer.clientID; self.onMessage?(m)
                } else {
                    guard trust.state.peers.contains(where: { $0.id == offer.clientID && $0.certificate == certificate }),
                          packet.type == "message", var m = packet.message,
                          ["list", "create", "attach", "claim", "release", "renew", "input", "resize", "terminate"].contains(m.type) else { throw SecureError.protocolViolation }
                    m.clientID = offer.clientID; self.onMessage?(m)
                }
            } catch { self.drop(offer.clientID) }
        }
        timeouts[offer.clientID] = Task { [weak self, weak transport] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.channels[offer.clientID] === transport else { return }; self.drop(offer.clientID)
        }
        // This TLS admission snapshot only permits a handshake. Authorization is checked
        // again against the live, persistent trust store before any application command.
        let peers = trust.state.peers.map(\.certificate)
        let enrollment = trust.state.pending.map { $0.expires > Date() && $0.attempts < 5 } ?? false
        Task { [weak self, weak transport] in
            guard let transport else { return }
            do { try await transport.connect(base: base, path: "v2/accept/\(offer.id)", token: credentials.token, identity: trust.state.identity, server: true, accepts: { enrollment || peers.contains($0) }) }
            catch { if let self, self.channels[offer.clientID] === transport { self.drop(offer.clientID) } }
        }
    }
    private func drop(_ id: String) {
        channels.removeValue(forKey: id)?.close(); timeouts.removeValue(forKey: id)?.cancel()
        if authorized.remove(id) != nil { var m = Message("clientDisconnected"); m.clientID = id; onMessage?(m) }
    }
    public func send(_ m: Message) {
        var p = SecurePacket(type: "message"); p.message = m
        for id in authorized where m.clientID == nil || m.clientID == id { channels[id]?.send(p) }
    }
    public func disconnect() {
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
    private var authorized = false
    private var generation = UUID()
    private var timeout: Task<Void, Never>?
    private let api = RelayClient()
    private let account: String
    public private(set) var saved: SecurePhoneConnection?
    public init(account: String = "secure-phone-v2") { self.account = account }
    public func restore() throws -> SecurePhoneConnection? { saved = try SecretStore.read(account); return saved }
    public func pair(invitation text: String, name: String = "iPhone") async throws -> SecurePhoneConnection {
        disconnect(); let pairingGeneration = generation
        let invite = try SecureInvitation.decode(text)
        let id = UUID().uuidString, token = try SecretStore.randomToken()
        let identity = try DeviceIdentity.create()
        let host: HostIdentity = try await api.request(URL(string: invite.server)!, path: "v2/clients", body: ["id": id, "token": token, "code": invite.code, "name": name])
        guard generation == pairingGeneration else { throw SecureError.disconnected }
        guard host.id == invite.hostID, host.code == invite.code else { throw SecureError.unauthorized }
        let next = SecurePhoneConnection(server: invite.server, credentials: ClientCredentials(clientID: id, token: token, host: host), identity: identity, hostFingerprint: invite.fingerprint, invitation: invite)
        try SecretStore.write(next, account: account); saved = next
        connect(); let connectionGeneration = generation
        for _ in 0..<300 {
            guard generation == connectionGeneration else { throw SecureError.disconnected }
            if authorized { return self.saved! }
            guard transport != nil else { throw SecureError.unauthorized }
            try await Task.sleep(for: .milliseconds(50))
        }
        disconnect(); throw SecureError.disconnected
    }
    public func connect() {
        disconnect()
        guard let saved else { return }
        let transport = SecureTransport(); self.transport = transport
        status = L10n.text("Conectando…")
        let nonce: String
        do { nonce = try SecretStore.randomToken() } catch { disconnect(); return }
        transport.onReady = { [weak self, weak transport] _ in
            guard let self, let transport, self.transport === transport else { return }
            var hello = SecurePacket(type: "hello"); hello.server = saved.server; hello.hostID = saved.credentials.host.id
            hello.clientID = saved.credentials.clientID; hello.nonce = nonce; hello.name = "iPhone"
            hello.invitationID = saved.invitation?.id; hello.secret = saved.invitation?.secret
            transport.send(hello)
        }
        transport.onPacket = { [weak self, weak transport] packet in
            guard let self, let transport, self.transport === transport else { return }
            do {
                guard packet.version == 2 else { throw SecureError.protocolViolation }
                if !self.authorized {
                    guard packet.type == "welcome", packet.server == saved.server, packet.hostID == saved.credentials.host.id,
                          packet.clientID == saved.credentials.clientID, packet.nonce == nonce,
                          packet.fingerprint == saved.identity.fingerprint else { throw SecureError.unauthorized }
                    var next = saved; next.invitation = nil
                    try SecretStore.write(next, account: self.account); self.saved = next
                    self.authorized = true; self.timeout?.cancel(); self.status = L10n.text("Conectado")
                    self.onMessage?(Message("welcome")); self.onMessage?(Message("hostOnline"))
                } else {
                    guard packet.type == "message", let m = packet.message else { throw SecureError.protocolViolation }
                    self.onMessage?(m)
                }
            } catch { self.disconnect() }
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
        generation = UUID(); transport?.close(); transport = nil; timeout?.cancel(); timeout = nil; authorized = false
        status = L10n.text("Sin conexión"); onDisconnect?()
    }
}
