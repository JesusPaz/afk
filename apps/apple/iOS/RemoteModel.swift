import Foundation
import Combine
import AFKCore

struct SavedConnection: Codable { let server: String; let credentials: ClientCredentials }

@MainActor
final class RemoteModel: ObservableObject {
    let relay = RelayClient()
    let feed = TerminalFeed()
    @Published var sessions: [SessionInfo] = []
    @Published var selected: String?
    @Published var error: String?
    @Published var status = "Sin conexión"
    @Published var ready = false
    @Published var owner = ""
    @Published var hostName = "Tu Mac"
    @Published var linked = false
    private var epoch: UInt64 = 0
    private var inputSequence: UInt64 = 0
    private var credentials: ClientCredentials?
    private var server: URL?
    private var subscription: AnyCancellable?
    private var renewal: Timer?
    var canWrite: Bool { ready && owner == credentials?.clientID }

    init() {
        relay.onMessage = { [weak self] in self?.receive($0) }
        relay.onDisconnect = { [weak self] in self?.ready = false; self?.owner = "" }
        subscription = relay.$status.sink { [weak self] in self?.status = $0 }
        renewal = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.canWrite else { return }
                var m = Message("renew", sessionID: self.selected); m.epoch = self.epoch; self.relay.send(m)
            }
        }
    }
    func restore() {
        do {
            if let saved: SavedConnection = try SecretStore.read("last-client") {
                credentials = saved.credentials; server = try ServerAddress.parse(saved.server); hostName = saved.credentials.host.name; linked = true; reconnect()
            }
        } catch { self.error = error.localizedDescription }
    }
    func pair(server: String, code: String, secret: String) async {
        do {
            let url = try ServerAddress.parse(server)
            let c: ClientCredentials = try await relay.request(url, path: "v1/pair", body: ["code": code, "secret": secret, "name": "iPhone"])
            try SecretStore.write(SavedConnection(server: url.absoluteString, credentials: c), account: "last-client")
            self.server = url; credentials = c; hostName = c.host.name; linked = true; error = nil; reconnect()
        } catch { self.error = error.localizedDescription }
    }
    func reconnect() { guard let server, let credentials else { return }; ready = false; relay.connect(server, token: credentials.token) }
    func attach(_ id: String) {
        if selected != id { release() }
        selected = id; ready = false; relay.send(Message("attach", sessionID: id))
    }
    func claim() { guard ready else { return }; relay.send(Message("claim", sessionID: selected)) }
    func release() { if canWrite { relay.send(Message("release", sessionID: selected)) }; owner = "" }
    func leave() { release(); selected = nil; ready = false }
    func suspend() { release(); relay.disconnect(); ready = false }
    func input(_ bytes: Data) {
        guard canWrite, bytes.count <= 8192 else { return }
        inputSequence += 1
        var m = Message("input", sessionID: selected); m.epoch = epoch; m.sequence = inputSequence; m.data = bytes.base64EncodedString(); relay.send(m)
    }
    func create() { var m = Message("create", sessionID: UUID().uuidString); m.name = "Shell"; relay.send(m) }
    private func receive(_ m: Message) {
        switch m.type {
        case "hostOnline", "welcome": relay.send(Message("list")); if let selected { attach(selected) }
        case "hostOffline": ready = false; owner = ""; status = "El Mac no está disponible"
        case "sessions": sessions = m.sessions ?? []
        case "snapshot":
            guard m.sessionID == selected, let data = m.data.flatMap({ Data(base64Encoded: $0) }) else { return }
            feed.reset(data, sequence: m.sequence ?? 0); owner = m.owner ?? ""; if epoch != m.epoch { inputSequence = 0 }; epoch = m.epoch ?? 0; ready = true
        case "output":
            guard ready, m.sessionID == selected, let sequence = m.sequence, sequence > feed.sequence else { return }
            guard sequence == feed.sequence + 1 else { if let selected { attach(selected) }; return }
            if let data = m.data.flatMap({ Data(base64Encoded: $0) }) { feed.sequence = sequence; feed.append(data) }
        case "control":
            guard m.sessionID == selected else { return }; owner = m.owner ?? ""; if epoch != m.epoch { inputSequence = 0 }; epoch = m.epoch ?? 0
        case "exit": if m.sessionID == selected { ready = false; owner = ""; error = m.message }
        case "error": error = m.message; if m.sessionID == selected { ready = false }
        default: break
        }
    }
}
