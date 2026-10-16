import Foundation
import Combine
import AFKCore

struct SavedConnection: Codable { let server: String; let credentials: ClientCredentials }

@MainActor
final class RemoteModel: ObservableObject {
    let relay = SecurePhoneRelay()
    private let unlock = LocalDeviceUnlock()
    private var reconnecting = false
    let feed = TerminalFeed()
    @Published var sessions: [SessionInfo] = []
    @Published var selected: String?
    @Published var error: String?
    @Published var status = L10n.text("Sin conexión")
    @Published var ready = false
    @Published var sessionNotice: String?
    @Published var owner = ""
    @Published var hostName = L10n.text("Tu Mac")
    @Published var linked = false
    @Published var hostAvailable = false
    private var epoch: UInt64 = 0
    private var inputSequence: UInt64 = 0
    private var viewport: TerminalSize?
    private var credentials: ClientCredentials?
    private var server: URL?
    private var subscription: AnyCancellable?
    private var renewal: Timer?
    var canWrite: Bool { ready && owner == credentials?.clientID }

    init() {
        relay.onMessage = { [weak self] in self?.receive($0) }
        relay.onDisconnect = { [weak self] in self?.ready = false; self?.owner = ""; self?.hostAvailable = false }
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
            if let saved = try relay.restore() {
                credentials = saved.credentials; server = try ServerAddress.parse(saved.server); hostName = saved.credentials.host.name; linked = true; reconnect()
            }
        } catch { self.error = error.localizedDescription }
    }
    func pair(server: String, code: String, secret: String) async {
        do {
            try await unlock.require()
            let saved = try await relay.pair(invitation: secret)
            self.server = try ServerAddress.parse(saved.server); credentials = saved.credentials
            hostName = saved.credentials.host.name; linked = true; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func reconnect() {
        guard !unlock.isBusy, !reconnecting else { return }
        ready = false; reconnecting = true
        Task {
            defer { reconnecting = false }
            do { try await unlock.require(); relay.connect() }
            catch { relay.disconnect(); self.error = error.localizedDescription }
        }
    }
    func attach(_ id: String) {
        if selected != id { release(); epoch = 0; inputSequence = 0 }
        selected = id; ready = false; sessionNotice = nil; relay.send(Message("attach", sessionID: id))
    }
    func claim() { guard ready else { return }; relay.send(Message("claim", sessionID: selected)) }
    func release() { if canWrite { relay.send(Message("release", sessionID: selected)) }; owner = "" }
    func leave() { release(); selected = nil; ready = false }
    func suspend() { unlock.invalidate(); release(); relay.disconnect(); ready = false; sessions = []; _ = feed.reset([], sequence: 0) }
    func resize(_ size: TerminalSize) {
        viewport = size
        sendSize()
    }
    private func sendSize() {
        guard canWrite, let viewport, viewport != feed.size else { return }
        inputSequence += 1
        var m = Message("resize", sessionID: selected)
        m.epoch = epoch; m.sequence = inputSequence; m.columns = viewport.columns; m.rows = viewport.rows
        relay.send(m)
    }
    func input(_ bytes: Data) {
        guard canWrite, bytes.count <= 8192 else { return }
        inputSequence += 1
        var m = Message("input", sessionID: selected); m.epoch = epoch; m.sequence = inputSequence; m.data = bytes.base64EncodedString(); relay.send(m)
    }
    func create() { var m = Message("create", sessionID: UUID().uuidString); m.name = L10n.format("Terminal %lld", sessions.count + 1); relay.send(m) }
    private func receive(_ m: Message) {
        switch m.type {
        case "welcome": relay.send(Message("list"))
        case "hostOnline": hostAvailable = true; relay.send(Message("list")); if let selected { attach(selected) }
        case "hostOffline": hostAvailable = false; ready = false; owner = ""; status = L10n.text("El Mac no está disponible")
        case "sessions": hostAvailable = true; sessions = m.sessions ?? []
        case "snapshot":
            guard m.sessionID == selected, let events = m.events, feed.reset(events, sequence: m.sequence ?? 0) else { return }
            owner = m.owner ?? ""; if epoch != m.epoch { inputSequence = 0 }; epoch = m.epoch ?? 0; ready = true; sendSize()
        case "output", "resized":
            guard ready, m.sessionID == selected, let sequence = m.sequence, sequence > feed.sequence else { return }
            guard sequence == feed.sequence + 1 else { if let selected { attach(selected) }; return }
            if m.type == "resized", let columns = m.columns, let rows = m.rows {
                feed.sequence = sequence; feed.resize(TerminalSize(columns: columns, rows: rows))
            }
            if let data = m.data.flatMap({ Data(base64Encoded: $0) }) { feed.sequence = sequence; feed.append(data) }
        case "control":
            guard m.sessionID == selected else { return }; owner = m.owner ?? ""; if epoch != m.epoch { inputSequence = 0 }; epoch = m.epoch ?? 0; sendSize()
        case "exit": if m.sessionID == selected { ready = false; owner = ""; sessionNotice = L10n.text("Sesión terminada") }
        case "error":
            if let sessionID = m.sessionID, sessionID == selected { ready = false; sessionNotice = m.message.map { L10n.text($0) } }
            else { error = m.message.map { L10n.text($0) } }
        default: break
        }
    }
}
