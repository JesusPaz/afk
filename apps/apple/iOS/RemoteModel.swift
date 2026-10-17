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
    private let historyRoot = FileManager.default.temporaryDirectory.appendingPathComponent("AFK-" + UUID().uuidString)
    private(set) var historyID: String?
    private var historyRequest: Task<Void, Never>?
    @Published var historyProgress: Double?
    deinit { try? FileManager.default.removeItem(at: historyRoot) }
    private func clearHistory() {
        historyRequest?.cancel(); historyRequest = nil
        historyID = nil; historyProgress = nil
        feed.replaceHistory(nil)
        try? FileManager.default.removeItem(at: historyRoot)
    }
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
    private lazy var inputBuffer = TerminalInputBuffer(send: { [weak self] in self?.sendInput($0, retry: $1) }, failed: { [weak self] in
        self?.release()
        self?.sessionNotice = L10n.text("El Mac no confirmó la entrada. Revisa la terminal antes de continuar.")
    })
    private var inputAcknowledgements = false
    private var epoch: UInt64 = 0
    private var inputSequence: UInt64 = 0
    private var viewport: TerminalSize?
    private var credentials: ClientCredentials?
    private var subscription: AnyCancellable?
    private var renewal: Timer?
    @Published var canCreate = false
    var selectedInfo: SessionInfo? { sessions.first { $0.id == selected } }
    var terminalStatus: String {
        if !hostAvailable { return L10n.text("Sin conexión. Reintenta para continuar.") }
        if selectedInfo?.running == false { return L10n.text("Sesión terminada") }
        if !ready { return L10n.text(sessionNotice == nil ? "Recuperando la sesión…" : "No se pudo abrir la sesión") }
        return L10n.text(canWrite ? "Estás escribiendo desde el iPhone" : "Estás viendo la sesión")
    }
    var canClaim: Bool { ready && inputAcknowledgements && selectedInfo?.canControl == true }
    var canTerminate: Bool { ready && selectedInfo?.canTerminate == true }
    var canWrite: Bool { canClaim && owner == credentials?.clientID }
    private func clearTerminal() {
        if inputBuffer.hasPendingInput { sessionNotice = L10n.text("Hay entrada sin confirmar. Revisa la terminal antes de volver a escribir.") }
        inputBuffer.cancel()
        ready = false; owner = ""; epoch = 0; inputSequence = 0
        clearHistory()
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
            guard generation == pairingGeneration else { throw SecureError.disconnected }
            let saved = try await relay.pair(invitation: invitation)
            credentials = saved.credentials
            hostName = saved.credentials.host.name; linked = true; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func reconnect() {
        guard !unlock.isBusy, !reconnecting, !pairing else { return }
        inputBuffer.cancel()
        historyID = nil; historyProgress = nil
        ready = false; reconnecting = true
        Task {
            defer { reconnecting = false }
            do {
                if relay.saved?.identity.requiresBiometry != true { try await unlock.require() }
                relay.connect()
            }
            catch { relay.disconnect(); self.error = error.localizedDescription }
        }
    }
    func attach(_ id: String) {
        if selected != id { release(); epoch = 0; inputSequence = 0 }
        inputBuffer.cancel()
        selected = id; ready = false; sessionNotice = nil
        clearHistory()
        do {
            feed.replaceHistory(try TerminalHistory(root: historyRoot, name: selectedInfo?.name ?? "Terminal"))
            historyID = UUID().uuidString; historyProgress = 0
            var request = Message("attach", sessionID: id); request.historyID = historyID
            relay.send(request)
        } catch { sessionNotice = error.localizedDescription }
    }
    func claim() { guard canClaim else { return }; relay.send(Message("claim", sessionID: selected)) }
    func release() { inputBuffer.cancel(); if canWrite { relay.send(Message("release", sessionID: selected)) }; owner = "" }
    func leave() { release(); selected = nil; ready = false; clearHistory() }
    func suspend() { cancelPairing(); unlock.invalidate(); release(); relay.disconnect(); ready = false; sessions = []; clearHistory() }
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
        guard canWrite else { return }
        guard inputBuffer.append(bytes) else {
            release()
            sessionNotice = L10n.text("La entrada es demasiado grande. Se detuvo el envío; revisa la terminal antes de continuar.")
            return
        }
    }
    private func sendInput(_ bytes: Data, retry: UInt64?) -> UInt64? {
        guard canWrite else { inputBuffer.cancel(); return nil }
        if retry == nil { inputSequence += 1 }
        var m = Message("input", sessionID: selected); m.epoch = epoch; m.sequence = retry ?? inputSequence; m.data = bytes.base64EncodedString(); relay.send(m)
        return m.sequence
    }
    func terminate() { guard canTerminate else { return }; relay.send(Message("terminate", sessionID: selected)) }
    func create() { guard canCreate else { return }; var m = Message("create", sessionID: UUID().uuidString); m.name = L10n.format("Terminal %lld", sessions.count + 1); relay.send(m) }
    private func receive(_ m: Message) {
        switch m.type {
        case "welcome": relay.send(Message("list"))
        case "hostOnline": hostAvailable = true; relay.send(Message("list")); if let selected { attach(selected) }
        case "hostOffline": clearHistory(); inputBuffer.cancel(); hostAvailable = false; ready = false; owner = ""; status = L10n.text("El Mac no está disponible")
        case "sessions":
            hostAvailable = true; sessions = m.sessions ?? []; canCreate = m.canCreate == true
            if let selected, !sessions.contains(where: { $0.id == selected }) {
                clearTerminal(); self.selected = nil; sessionNotice = L10n.text("El Mac retiró el acceso a esta sesión.")
            } else if !canClaim { inputBuffer.cancel(); owner = "" }

        case "historyChunk":
            guard m.sessionID == selected, selectedInfo != nil, let id = historyID, m.historyID == id,
                  let events = m.events, events.allSatisfy(\.isValid), let offset = m.historyOffset,
                  let length = m.historyLength, offset <= length else { return }
            for event in events {
                if let size = event.size { feed.resize(size) }
                if let data = event.data { feed.append(data) }
            }
            if let error = feed.historyError {
                historyID = nil; historyProgress = nil; sessionNotice = error; return
            }
            historyRequest?.cancel(); historyRequest = nil
            historyProgress = length == 0 ? 1 : Double(offset) / Double(length)
            if m.historyComplete == true {
                feed.sequence = m.sequence ?? 0
                inputAcknowledgements = m.inputAcknowledgements == true
                owner = m.owner ?? ""; epoch = m.epoch ?? 0; inputSequence = 0
                historyID = nil; historyProgress = nil; ready = true; sendSize()
            } else {
                var next = Message("historyNext", sessionID: selected)
                next.historyID = id; next.historyOffset = offset
                // Stay below relay frame/byte budgets even on a fast LAN and yield to rendering.
                historyRequest = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                    guard let self, self.historyID == id else { return }
                    self.relay.send(next)
                }
            }
        case "snapshot":
            guard m.sessionID == selected, selectedInfo != nil, let events = m.events, feed.reset(events, sequence: m.sequence ?? 0) else { return }
            historyID = nil; historyProgress = nil
            // Older hosts send one bounded snapshot instead of disk-backed chunks.
            do { for event in events { try feed.history?.append(event) } }
            catch { sessionNotice = error.localizedDescription; return }
            if owner != (m.owner ?? "") || epoch != m.epoch { inputBuffer.cancel() }
            inputAcknowledgements = m.inputAcknowledgements == true
            if !inputAcknowledgements { sessionNotice = L10n.text("Actualiza AFK en el Mac para escribir con confirmación de entrega.") }
            owner = m.owner ?? ""; if epoch != m.epoch { inputSequence = 0 }; epoch = m.epoch ?? 0; ready = true; sendSize()
        case "output", "resized":
            guard ready, m.sessionID == selected, let sequence = m.sequence, sequence > feed.sequence else { return }
            guard sequence == feed.sequence + 1 else { if let selected { attach(selected) }; return }
            if m.type == "resized", let columns = m.columns, let rows = m.rows {
                feed.sequence = sequence; feed.resize(TerminalSize(columns: columns, rows: rows))
            }
            if let data = m.data.flatMap({ Data(base64Encoded: $0) }) { feed.sequence = sequence; feed.append(data) }
        case "control":
            guard m.sessionID == selected else { return }; if owner != (m.owner ?? "") || epoch != m.epoch { inputBuffer.cancel() }
            owner = m.owner ?? ""; if epoch != m.epoch { inputSequence = 0 }; epoch = m.epoch ?? 0; sendSize()
        case "inputAck":
            guard m.sessionID == selected, m.epoch == epoch, let sequence = m.sequence else { return }
            inputBuffer.acknowledge(sequence)
        case "exit":
            if m.sessionID == selected {
                inputBuffer.cancel(); ready = false; owner = ""; sessionNotice = L10n.text("Sesión terminada")
                if let index = sessions.firstIndex(where: { $0.id == selected }) { sessions[index].running = false }
            }
        case "error":
            if let sessionID = m.sessionID, sessionID == selected { historyID = nil; historyProgress = nil; inputBuffer.cancel(); ready = false; sessionNotice = m.message.map { L10n.text($0) } }
            else { error = m.message.map { L10n.text($0) } }
        default: break
        }
    }
}
