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
    @Published public private(set) var connectionStatus = "Acceso remoto desconectado"
    private var base: URL?
    private var secret: HostSecret?
    private var timer: Timer?
    private var statusSubscription: AnyCancellable?

    public init() {
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
        guard sessions.count < 8 else { error = "El POC permite hasta ocho sesiones."; return nil }
        let session = HostSession(id: id, name: String(name.prefix(60)))
        session.onEvent = { [weak self] in self?.relay.send($0) }
        session.onState = { [weak self] in self?.publishSessions() }
        sessions.append(session); session.start(); publishSessions(); return session
    }
    public func connect(server: String, credentials: HostSecret? = nil) async {
        do {
            let url = try ServerAddress.parse(server)
            let saved: HostSecret? = try credentials ?? SecretStore.read("host:\(url.absoluteString)")
            let identity = try saved ?? HostSecret(token: SecretStore.randomToken())
            if credentials == nil { try SecretStore.write(identity, account: "host:\(url.absoluteString)") }
            let h: HostIdentity = try await relay.request(url, path: "v1/hosts", body: ["id": identity.id, "token": identity.token, "name": Host.current().localizedName ?? "Mac"])
            base = url; secret = identity; host = h; relay.connect(url, token: identity.token); error = nil
        } catch { self.error = error.localizedDescription }
    }
    public func makePairing() async {
        guard let base, let secret else { error = "Conecta el Mac al relay primero."; return }
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
    public func pause() { relay.disconnect(); pairing = nil }
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
            var reply = Message("snapshot", sessionID: session.id); reply.clientID = client; reply.data = bytes.base64EncodedString(); reply.sequence = session.feed.sequence
            reply.owner = session.lease.owner; reply.epoch = session.lease.epoch; reply.columns = 80; reply.rows = 24; relay.send(reply)
        case "claim": session.claim(client)
        case "release": session.release(client)
        case "renew": session.renew(client, epoch: m.epoch ?? 0)
        case "input":
            guard let data = m.data.flatMap({ Data(base64Encoded: $0) }), let epoch = m.epoch, let sequence = m.sequence else { return }
            session.input(data, client: client, epoch: epoch, sequence: sequence)
        case "terminate": session.terminate()
        default: break
        }
    }
}
#endif
