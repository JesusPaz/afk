import Foundation
import Combine
import AFKCore

@MainActor
final class RemoteModel: ObservableObject {
    let relay = SecurePhoneRelay()
    private let unlock = LocalDeviceUnlock()
    private var reconnecting = false
    private var pairing = false
    private var pairingGeneration = UUID()
    @Published var comparisonCode: String?
    private var pairingSubscription: AnyCancellable?
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
    private var subscription: AnyCancellable?
    private var renewal: Timer?
    @Published var canCreate = false
    var selectedInfo: SessionInfo? { sessions.first { $0.id == selected } }
    var canClaim: Bool { ready && selectedInfo?.canControl == true }
    var canTerminate: Bool { ready && selectedInfo?.canTerminate == true }
    var canWrite: Bool { canClaim && owner == credentials?.clientID }
    private func clearTerminal() {
        ready = false; owner = ""; epoch = 0; inputSequence = 0
        _ = feed.reset([], sequence: 0)
    }

    init() {
        relay.onMessage = { [weak self] in self?.receive($0) }
        relay.onDisconnect = { [weak self] in
            self?.clearTerminal(); self?.sessions = []; self?.canCreate = false; self?.hostAvailable = false
        }
        pairingSubscription = relay.$comparisonCode.sink { [weak self] in self?.comparisonCode = $0 }
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
                credentials = saved.credentials; hostName = saved.credentials.host.name; linked = true; reconnect()
            }
        } catch { self.error = error.localizedDescription }
    }
    func cancelPairing() {
        pairingGeneration = UUID(); unlock.invalidate()
        if pairing { relay.disconnect() }
    }
    func pair(invitation: String) async {
        guard !pairing else { return }
        pairing = true; let generation = pairingGeneration
        defer { pairing = false }
        do {
            _ = try SecureInvitation.decode(invitation)
            try await unlock.require()
            guard generation == pairingGeneration else { throw SecureError.disconnected }
            let saved = try await relay.pair(invitation: invitation)
            credentials = saved.credentials
            hostName = saved.credentials.host.name; linked = true; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func reconnect() {
        guard !unlock.isBusy, !reconnecting, !pairing else { return }
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
    func claim() { guard canClaim else { return }; relay.send(Message("claim", sessionID: selected)) }
    func release() { if canWrite { relay.send(Message("release", sessionID: selected)) }; owner = "" }
    func leave() { release(); selected = nil; ready = false }
    func suspend() { cancelPairing(); unlock.invalidate(); release(); relay.disconnect(); ready = false; sessions = []; _ = feed.reset([], sequence: 0) }
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
    func terminate() { guard canTerminate else { return }; relay.send(Message("terminate", sessionID: selected)) }
    func create() { guard canCreate else { return }; var m = Message("create", sessionID: UUID().uuidString); m.name = L10n.format("Terminal %lld", sessions.count + 1); relay.send(m) }
    private func receive(_ m: Message) {
        switch m.type {
        case "welcome": relay.send(Message("list"))
        case "hostOnline": hostAvailable = true; relay.send(Message("list")); if let selected { attach(selected) }
        case "hostOffline": hostAvailable = false; ready = false; owner = ""; status = L10n.text("El Mac no está disponible")
        case "sessions":
            hostAvailable = true; sessions = m.sessions ?? []; canCreate = m.canCreate == true
            if let selected, !sessions.contains(where: { $0.id == selected }) {
                clearTerminal(); self.selected = nil; sessionNotice = L10n.text("El Mac retiró el acceso a esta sesión.")
            } else if !canClaim { owner = "" }

        case "snapshot":
            guard m.sessionID == selected, selectedInfo != nil, let events = m.events, feed.reset(events, sequence: m.sequence ?? 0) else { return }
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
