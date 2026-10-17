#if os(macOS)
import Foundation
import Combine
import AFKCore

public struct HostSecret: Codable {
    public let id: String
    public let token: String
    public init(id: String = UUID().uuidString, token: String) { self.id = id; self.token = token }
}

@MainActor
public final class HostController: ObservableObject {
    public let relay = SecureHostRelay()
    @Published public private(set) var sessions: [HostSession] = []
    @Published public private(set) var host: HostIdentity?
    @Published public private(set) var pairing: Pairing?
    @Published public private(set) var clients: [PairedClient] = []
    @Published public var error: String?
    @Published public private(set) var connectionStatus = L10n.text("Acceso remoto desconectado")
    @Published public private(set) var connecting = false
    @Published public private(set) var remoteAccessPaused: Bool
    public private(set) var accessRevision: UInt64 = 0
    public let access: RemoteAccess
    @Published public private(set) var connectedClients: Set<String> = []
    private let history: AccessHistory
    public var accessEvents: [AccessEvent] { history.events }
    private let preferences: UserDefaults
    private var restoredConnection = false
    private var base: URL?
    private var secret: HostSecret?
    private var timer: Timer?
    private let pairingUnlock = LocalDeviceUnlock()
    private var pairingGeneration = UUID()
    private var lockObserver: NSObjectProtocol?
    private var statusSubscription: AnyCancellable?

    public init(preferences: UserDefaults = .standard, access: RemoteAccess? = nil) {
        self.preferences = preferences
        self.access = access ?? RemoteAccess(); history = AccessHistory(preferences: preferences)
        remoteAccessPaused = preferences.bool(forKey: "remoteAccessPaused")
        relay.onPairingEnded = { [weak self] in self?.pairing = nil }
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancelPairing() }
        }
        relay.onMessage = { [weak self] in self?.receive($0) }
        relay.onDisconnect = { [weak self] in
            guard let self else { return }
            for session in self.sessions where session.lease.owner != "local" { session.release(session.lease.owner) }
        }
        statusSubscription = relay.$status.sink { [weak self] in self?.connectionStatus = $0 }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    deinit { if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) } }
    @discardableResult
    public func create(name: String = "Shell", id: String = UUID().uuidString) -> HostSession? {
        if let existing = sessions.first(where: { $0.id == id }) { return existing }
        guard sessions.count < 8 else { error = L10n.text("El POC permite hasta ocho sesiones."); return nil }
        let session = HostSession(id: id, name: String(name.prefix(60)))
        session.onEvent = { [weak self] in self?.forward($0) }
        session.onState = { [weak self] in self?.publishSessions() }
        sessions.append(session); session.start(); publishSessions(); return session
    }
    public func restoreConnection(server: String) async {
        guard !restoredConnection else { return }
        restoredConnection = true
        guard !remoteAccessPaused else { return }
        await connect(server: server)
    }
    public func connect(server: String, credentials: HostSecret? = nil) async {
        guard !connecting else { return }
        connecting = true
        defer { connecting = false }
        do {
            let url = try ServerAddress.parse(server)
            let saved: HostSecret? = try credentials ?? SecretStore.read("host:\(url.absoluteString)")
            let identity = try saved ?? HostSecret(token: SecretStore.randomToken())
            if credentials == nil && saved == nil { try SecretStore.write(identity, account: "host:\(url.absoluteString)") }
            if base != nil && (base != url || secret?.id != identity.id) { stopRemoteAccess() }
            let h = try await relay.connect(url, id: identity.id, token: identity.token, name: Host.current().localizedName ?? "Mac")
            remoteAccessPaused = false; preferences.set(false, forKey: "remoteAccessPaused")
            base = url; secret = identity; host = h; error = nil
        } catch { self.error = error.localizedDescription }
    }
    public func cancelPairing() {
        pairingGeneration = UUID(); pairingUnlock.invalidate(); pairing = nil
        do { try relay.cancelInvitation() } catch { self.error = error.localizedDescription }
    }
    public func beginPairing(server: String) async {
        cancelPairing()
        let generation = pairingGeneration
        if !relay.connected { await connect(server: server) }
        guard generation == pairingGeneration, !Task.isCancelled, error == nil else { return }
        do {
            try await pairingUnlock.require()
            guard generation == pairingGeneration, !Task.isCancelled else { return }
            await makePairing()
        } catch { self.error = error.localizedDescription }
    }
    public func approvePairing(_ id: UUID) async {
        error = nil
        do {
            try await pairingUnlock.require()
            try relay.approvePairing(id)
            clients = relay.clients
        } catch { self.error = error.localizedDescription }
    }
    public func makePairing() async {
        guard base != nil, secret != nil else { error = L10n.text("Conecta el Mac al relay primero."); return }
        do { pairing = try relay.invitation() }
        catch { self.error = error.localizedDescription }
    }
    public func refreshClients(server: String? = nil) async {
        do {
            if let server, !relay.connected {
                let url = try ServerAddress.parse(server)
                if let identity: HostSecret = try SecretStore.read("host:\(url.absoluteString)") {
                    try relay.restoreTrust(url, id: identity.id, token: identity.token)
                }
            }
            clients = relay.clients
        } catch { self.error = error.localizedDescription }
    }
    public func revoke(_ id: String) async {
        accessRevision += 1
        access.remove(client: id); releaseControl(id); record(.revoked, client: id); publishSessions()
        do { try await relay.revoke(id); await refreshClients() }
        catch {
            clients = relay.clients; self.error = error.localizedDescription
            if !relay.connected { remoteAccessPaused = true; preferences.set(true, forKey: "remoteAccessPaused") }
        }
    }
    public func pause() {
        cancelPairing()
        accessRevision += 1
        remoteAccessPaused = true; preferences.set(true, forKey: "remoteAccessPaused")
        access.removeAll(); relay.disconnect(); pairing = nil
        do { try relay.cancelInvitation() } catch { self.error = error.localizedDescription }
        record(.stopped)
    }
    public func shutdown() { relay.disconnect(); sessions.forEach { $0.terminate() }; timer?.invalidate() }
    public func stopRemoteAccess() { pause() }
    public func revokeAllDevices() {
        pause()
        do { try relay.revokeAll(); clients = relay.clients; record(.revoked) }
        catch { self.error = error.localizedDescription }
    }
    public func setAccess(client: String, session: String, level: SessionAccess, duration: TimeInterval = 3600, allowClose: Bool = false) {
        guard relay.clients.contains(where: { $0.id == client }), sessions.contains(where: { $0.id == session }) else { return }
        access.set(client: client, session: session, level: level, duration: duration, allowClose: allowClose)
        if level != .control { sessions.first(where: { $0.id == session })?.release(client) }
        record(level == .none ? .permissionsRemoved : .shared, client: client, session: session)
        publishSessions(to: client)
    }
    public func setCreation(client: String, duration: TimeInterval?) {
        guard relay.clients.contains(where: { $0.id == client }) else { return }
        access.setCreation(client: client, duration: duration)
        record(duration == nil ? .permissionsRemoved : .creationGranted, client: client)
        publishSessions(to: client)
    }
    private func record(_ kind: AccessEvent.Kind, client: String? = nil, session: String? = nil) {
        history.record(kind, client: client, session: session); objectWillChange.send()
    }
    private func releaseControl(_ client: String) { sessions.forEach { $0.release(client) } }
    func tick() {
        do { try relay.expireInvitationIfNeeded() } catch { self.error = error.localizedDescription }
        let expired = access.expire()
        for (client, session) in expired { record(.expired, client: client, session: session) }
        for session in sessions {
            let owner = session.lease.owner
            if owner != "local" && !owner.isEmpty && access.level(client: owner, session: session.id) != .control { session.release(owner) }
            session.expireControl()
        }
        if !expired.isEmpty { publishSessions() }
    }
    func visibleSessions(for client: String) -> [SessionInfo] {
        sessions.compactMap { session in
            guard access.level(client: client, session: session.id) != .none else { return nil }
            var info = session.info
            info.canControl = access.level(client: client, session: session.id) == .control
            info.canTerminate = access.canClose(client: client, session: session.id)
            info.controlExpiresAt = access.controlUntil(client: client, session: session.id)
            return info
        }
    }
    private func publishSessions(to client: String? = nil) {
        objectWillChange.send()
        for id in connectedClients where client == nil || client == id {
            var m = Message("sessions"); m.sessions = visibleSessions(for: id); m.clientID = id
            m.canCreate = access.canCreate(client: id); relay.send(m)
        }
    }
    private func forward(_ message: Message) {
        guard let session = message.sessionID else { return }
        for client in connectedClients where access.level(client: client, session: session) != .none {
            var m = message; m.clientID = client; relay.send(m)
        }
    }
    private func deny(_ client: String, session: String? = nil) {
        record(.denied, client: client, session: session)
        sendError("El Mac no ha autorizado esta operación.", client: client)
        publishSessions(to: client)
    }
    private func sendError(_ text: String, client: String, session: String? = nil) {
        var m = Message("error", sessionID: session); m.clientID = client; m.message = text; relay.send(m)
    }
    func receive(_ m: Message) {
        guard let client = m.clientID else { return }
        if m.type == "clientConnected" {
            connectedClients.insert(client); clients = relay.clients; record(.connected, client: client); publishSessions(to: client); return
        }
        if m.type == "clientDisconnected" { connectedClients.remove(client); releaseControl(client); record(.disconnected, client: client); return }
        guard connectedClients.contains(client) else { return }
        tick()
        if m.type == "list" { publishSessions(to: client); return }
        if m.type == "create" {
            guard let id = m.sessionID, UUID(uuidString: id) != nil else { return }
            guard access.canCreate(client: client), !sessions.contains(where: { $0.id == id }) else { deny(client); return }
            guard let created = create(name: m.name ?? "Shell", id: id) else { return }
            access.created(client: client, session: created.id)
            record(.shared, client: client, session: created.id); publishSessions(); return
        }
        guard let session = sessions.first(where: { $0.id == m.sessionID }), access.level(client: client, session: session.id) != .none else { deny(client); return }
        if ["claim", "renew", "input", "resize"].contains(m.type), access.level(client: client, session: session.id) != .control { deny(client, session: session.id); return }
        if m.type == "terminate", !access.canClose(client: client, session: session.id) { deny(client, session: session.id); return }
        switch m.type {
        case "attach":
            record(.viewed, client: client, session: session.id)
            guard let bytes = session.feed.snapshot else {
                sendError("El historial supera el límite del POC. La sesión continúa en el Mac; abre una nueva para compartirla.", client: client, session: session.id); return
            }
            var reply = Message("snapshot", sessionID: session.id); reply.clientID = client; reply.events = bytes; reply.sequence = session.feed.sequence
            reply.owner = session.lease.owner; reply.epoch = session.lease.epoch; reply.columns = session.feed.size.columns; reply.rows = session.feed.size.rows; relay.send(reply)
        case "claim":
            access.claimed(client: client, session: session.id); session.claim(client); record(.controlTaken, client: client, session: session.id)
        case "release": session.release(client)
        case "renew": session.renew(client, epoch: m.epoch ?? 0)
        case "input":
            guard let data = m.data.flatMap({ Data(base64Encoded: $0) }), let epoch = m.epoch, let sequence = m.sequence else { return }
            if session.input(data, client: client, epoch: epoch, sequence: sequence) { access.acceptedInput(client: client, session: session.id) }
        case "resize":
            guard let columns = m.columns, let rows = m.rows, let epoch = m.epoch, let sequence = m.sequence else { return }
            session.resize(TerminalSize(columns: columns, rows: rows), client: client, epoch: epoch, sequence: sequence)
        case "terminate": session.terminate()
        default: break
        }
    }
}
#endif
