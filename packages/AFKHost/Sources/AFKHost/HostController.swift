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
    public let relay = RelayClient()
    @Published public private(set) var sessions: [HostSession] = []
    @Published public private(set) var host: HostIdentity?
    @Published public private(set) var pairing: Pairing?
    @Published public private(set) var clients: [PairedClient] = []
    @Published public var error: String?
    @Published public private(set) var connectionStatus = L10n.text("Acceso remoto desconectado")
    @Published public private(set) var connecting = false
    @Published public private(set) var remoteAccessPaused: Bool
    private let preferences: UserDefaults
    private var restoredConnection = false
    private var base: URL?
    private var secret: HostSecret?
    private var timer: Timer?
    private var statusSubscription: AnyCancellable?

    public init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        remoteAccessPaused = preferences.bool(forKey: "remoteAccessPaused")
        relay.onMessage = { [weak self] in self?.receive($0) }
        relay.onDisconnect = { [weak self] in
            guard let self else { return }
            for session in self.sessions where session.lease.owner != "local" { session.release(session.lease.owner) }
        }
        statusSubscription = relay.$status.sink { [weak self] in self?.connectionStatus = $0 }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessions.forEach { $0.expireControl() } }
        }
    }
    @discardableResult
    public func create(name: String = "Shell", id: String = UUID().uuidString) -> HostSession? {
        if let existing = sessions.first(where: { $0.id == id }) { return existing }
        guard sessions.count < 8 else { error = L10n.text("El POC permite hasta ocho sesiones."); return nil }
        let session = HostSession(id: id, name: String(name.prefix(60)))
        session.onEvent = { [weak self] in self?.relay.send($0) }
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
            let h: HostIdentity = try await relay.request(url, path: "v1/hosts", body: ["id": identity.id, "token": identity.token, "name": Host.current().localizedName ?? "Mac"])
            remoteAccessPaused = false; preferences.set(false, forKey: "remoteAccessPaused")
            base = url; secret = identity; host = h; relay.connect(url, token: identity.token); error = nil
        } catch { self.error = error.localizedDescription }
    }
    public func makePairing() async {
        guard let base, let secret else { error = L10n.text("Conecta el Mac al relay primero."); return }
        do { pairing = try await relay.request(base, path: "v1/pairing", token: secret.token) }
        catch { self.error = error.localizedDescription }
    }
    public func refreshClients() async {
        guard let base, let secret else { return }
        do { clients = try await relay.request(base, path: "v1/clients", method: "GET", token: secret.token) }
        catch { self.error = error.localizedDescription }
    }
    public func revoke(_ id: String) async {
        guard let base, let secret else { return }
        do { try await relay.revoke(base, token: secret.token, clientID: id); await refreshClients() }
        catch { self.error = error.localizedDescription }
    }
    public func pause() {
        remoteAccessPaused = true; preferences.set(true, forKey: "remoteAccessPaused")
        relay.disconnect(); pairing = nil
    }
    public func shutdown() { relay.disconnect(); sessions.forEach { $0.terminate() }; timer?.invalidate() }
    private func publishSessions(to client: String? = nil) {
        objectWillChange.send()
        var m = Message("sessions"); m.sessions = sessions.map(\.info); m.clientID = client; relay.send(m)
    }
    private func sendError(_ text: String, client: String, session: String? = nil) {
        var m = Message("error", sessionID: session); m.clientID = client; m.message = text; relay.send(m)
    }
    private func receive(_ m: Message) {
        guard let client = m.clientID else { return }
        if m.type == "clientConnected" || m.type == "list" { publishSessions(to: client); return }
        if m.type == "clientDisconnected" { sessions.forEach { $0.release(client) }; return }
        if m.type == "create" {
            guard let id = m.sessionID, UUID(uuidString: id) != nil else { return }
            _ = create(name: m.name ?? "Shell", id: id); return
        }
        guard let session = sessions.first(where: { $0.id == m.sessionID }) else { return }
        switch m.type {
        case "attach":
            guard let bytes = session.feed.snapshot else {
                sendError("El historial supera el límite del POC. La sesión continúa en el Mac; abre una nueva para compartirla.", client: client, session: session.id); return
            }
            var reply = Message("snapshot", sessionID: session.id); reply.clientID = client; reply.events = bytes; reply.sequence = session.feed.sequence
            reply.owner = session.lease.owner; reply.epoch = session.lease.epoch; reply.columns = session.feed.size.columns; reply.rows = session.feed.size.rows; relay.send(reply)
        case "claim": session.claim(client)
        case "release": session.release(client)
        case "renew": session.renew(client, epoch: m.epoch ?? 0)
        case "input":
            guard let data = m.data.flatMap({ Data(base64Encoded: $0) }), let epoch = m.epoch, let sequence = m.sequence else { return }
            session.input(data, client: client, epoch: epoch, sequence: sequence)
        case "resize":
            guard let columns = m.columns, let rows = m.rows, let epoch = m.epoch, let sequence = m.sequence else { return }
            session.resize(TerminalSize(columns: columns, rows: rows), client: client, epoch: epoch, sequence: sequence)
        case "terminate": session.terminate()
        default: break
        }
    }
}
#endif
