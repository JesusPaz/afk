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
    private(set) var viewportID: String?
    private var viewportBytes = Data()
    private var viewportSequence: UInt64?
    private lazy var scrollback = RemoteScrollback(feed: feed)
    @Published var loadingHistory = false
    private var viewportAck: Task<Void, Never>?
    private var attachmentTimeout: Task<Void, Never>?
    private var prefetchedHistory = false
    func scrollHistory(older: Bool) {
        guard ready || selectedInfo?.running == false, viewportID != nil else { return }
        sendHistory(scrollback.request(older: older))
        sendHistory(scrollback.prefetch(older: older))
        loadingHistory = scrollback.waitingForHistory
        objectWillChange.send()
    }
    private func sendHistory(_ request: Message?) {
        guard var request, let viewportID else { return }
        request.sessionID = selected; request.viewportID = viewportID
        relay.send(request)
    }
    func scrollApplication(_ lines: Int) -> Bool {
        guard let viewport = scrollback.viewport,
              let bytes = lines > 0 ? viewport.scrollUp : viewport.scrollDown,
              !bytes.isEmpty, bytes.count <= 64 else { return false }
        // Application-owned history is input, subject to the same lease and acknowledgements.
        guard lines != 0 else { return true }
        guard canWrite else { return false }
        var inputBytes = Data()
        for _ in 0..<min(8, abs(lines)) { inputBytes.append(bytes) }
        input(inputBytes)
        return true
    }
    private func cancelInput() {
        inputBuffer.cancel()
        feed.onCancelApplicationScroll?()
    }
    private func clearHistory() {
        viewportAck?.cancel(); viewportAck = nil
        attachmentTimeout?.cancel(); attachmentTimeout = nil
        prefetchedHistory = false
        viewportID = nil; viewportBytes = Data(); viewportSequence = nil
        scrollback.clear(); loadingHistory = false
    }
    @Published var sessions: [SessionInfo] = []
    @Published private(set) var hiddenSessionIDs: Set<String> = []
    @Published var lastHiddenSessionID: String?
    private let preferences: UserDefaults
    private var hiddenHostID: String?
    var visibleSessions: [SessionInfo] { sessions.filter { !hiddenSessionIDs.contains($0.id) } }
    var hiddenSessions: [SessionInfo] { sessions.filter { hiddenSessionIDs.contains($0.id) } }
    func loadHiddenSessions(hostID: String) {
        hiddenHostID = hostID
        hiddenSessionIDs = Set(preferences.stringArray(forKey: "hiddenSessions." + hostID) ?? [])
        lastHiddenSessionID = nil
    }
    func hideSession(_ id: String) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        if selected == id { leave() }
        hiddenSessionIDs.insert(id); lastHiddenSessionID = id
        saveHiddenSessions()
    }
    func showSession(_ id: String) {
        hiddenSessionIDs.remove(id)
        if lastHiddenSessionID == id { lastHiddenSessionID = nil }
        saveHiddenSessions()
    }
    private func saveHiddenSessions() {
        guard let hiddenHostID else { return }
        preferences.set(Array(hiddenSessionIDs).sorted(), forKey: "hiddenSessions." + hiddenHostID)
    }
    func closeActionTitle(_ session: SessionInfo) -> String {
        L10n.text(session.canRemove == true ? (session.running ? "Cerrar y quitar…" : "Quitar de la lista") : "Terminar sesión")
    }
    func canCloseSession(_ session: SessionInfo) -> Bool {
        hostAvailable && session.canTerminate == true && session.closing != true && (session.running || session.canRemove == true)
    }
    func closeSession(_ id: String) {
        guard hostAvailable, let info = sessions.first(where: { $0.id == id }),
              canCloseSession(info) else { return }
        guard info.canRemove == true else {
            relay.send(Message("terminate", sessionID: id)); return
        }
        if selected == id { release(); ready = false; clearHistory() }
        if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].closing = true }
        relay.send(Message("closeAndRemove", sessionID: id))
    }
    @Published var selected: String?
    @Published var error: String?
    @Published var status = L10n.text("Sin conexión")
    @Published var ready = false
    @Published var sessionNotice: String?
    @Published private(set) var diagnostic: String?
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
    private var recoveryTimer: Timer?
    private var active = false
    private var restored = false
    private var retryDelay: TimeInterval = 2
    private var nextConnectionAttempt: TimeInterval = 0
    @Published var canCreate = false
    var selectedInfo: SessionInfo? { sessions.first { $0.id == selected } }
    var terminalStatus: String {
        if !hostAvailable { return L10n.text("Sin conexión. Reintenta para continuar.") }
        if selectedInfo?.closing == true { return L10n.text("Cerrando…") }
        if selectedInfo?.running == false { return L10n.text("Sesión terminada") }
        if !ready { return L10n.text(sessionNotice == nil ? "Recuperando la sesión…" : "No se pudo abrir la sesión") }
        return L10n.text(canWrite ? "Estás escribiendo desde el iPhone" : "Estás viendo la sesión")
    }
    var canClaim: Bool { selectedInfo?.closing != true && ready && inputAcknowledgements && selectedInfo?.canControl == true }
    var canTerminate: Bool { selectedInfo.map(canCloseSession) ?? false }
    var canWrite: Bool { canClaim && !scrollback.browsing && owner == credentials?.clientID }
    var ownsControl: Bool { !owner.isEmpty && owner == credentials?.clientID }
    var browsingHistory: Bool { scrollback.browsing }
    /// Leaves history without re-claiming, so a phone that already types keeps its lease.
    func returnToLive() { scrollback.returnToLive(); loadingHistory = false; objectWillChange.send() }
    private func clearTerminal() {
        if inputBuffer.hasPendingInput { sessionNotice = L10n.text("Hay entrada sin confirmar. Revisa la terminal antes de volver a escribir.") }
        cancelInput()
        ready = false; owner = ""; epoch = 0; inputSequence = 0
        clearHistory()
    }

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        feed.onHistoryEdge = { [weak self] in self?.scrollHistory(older: $0) }
        feed.onApplicationScroll = { [weak self] in self?.scrollApplication($0) ?? false }
        relay.onMessage = { [weak self] in self?.receive($0) }
        relay.onDisconnect = { [weak self] in
            guard let self else { return }
            let pendingInput = self.inputBuffer.hasPendingInput
            self.clearTerminal(); self.sessions = []; self.canCreate = false; self.hostAvailable = false
            if let failure = self.relay.failure {
                self.diagnostic = self.relay.diagnostic
                self.sessionNotice = [pendingInput ? self.sessionNotice : nil, failure].compactMap { $0 }.joined(separator: "\n")
            }
        }
        pairingSubscription = relay.$comparisonCode.sink { [weak self] in self?.comparisonCode = $0 }
        subscription = relay.$status.sink { [weak self] in self?.status = $0 }
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkConnection() }
        }
        renewal = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.canClaim, self.owner == self.credentials?.clientID else { return }
                var m = Message("renew", sessionID: self.selected); m.epoch = self.epoch; self.relay.send(m)
            }
        }
    }
    func restore() {
        guard !restored else { return }; restored = true; active = true
        do {
            if let saved = try relay.restore() {
                credentials = saved.credentials; loadHiddenSessions(hostID: saved.credentials.host.id); hostName = saved.credentials.host.name; linked = true; reconnect()
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
            loadHiddenSessions(hostID: saved.credentials.host.id)
            hostName = saved.credentials.host.name; linked = true; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func activate() {
        let resumed = !active; active = true
        guard linked else { return }
        if resumed && !relay.isConnected && !relay.isConnecting { reconnect() }
        else { checkConnection(force: true) }
    }
    func checkConnection(force: Bool = false) {
        guard active, linked, !pairing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        relay.checkConnection(now: now, force: force)
        if relay.isConnected { retryDelay = 2; nextConnectionAttempt = 0; return }
        guard relay.retryable, !relay.isConnecting, now >= nextConnectionAttempt else { return }
        reconnect(automatic: true)
    }
    func reconnect(automatic: Bool = false) {
        guard !unlock.isBusy, !reconnecting, !pairing else { return }
        if !automatic { active = true; retryDelay = 2 }
        nextConnectionAttempt = ProcessInfo.processInfo.systemUptime + retryDelay
        retryDelay = min(30, retryDelay * 2)
        cancelInput()
        clearHistory()
        ready = false; sessionNotice = nil; reconnecting = true
        Task {
            defer { reconnecting = false }
            do {
                if relay.saved?.identity.requiresBiometry != true { try await unlock.require() }
                guard active else { return }
                relay.connect()
            }
            catch { relay.disconnect(); self.error = error.localizedDescription }
        }
    }
    func attach(_ id: String) {
        guard sessions.contains(where: { $0.id == id }), !hiddenSessionIDs.contains(id) else { return }
        if selected != id { release(); epoch = 0; inputSequence = 0 }
        cancelInput()
        selected = id; ready = false; sessionNotice = nil
        clearHistory()
        viewportID = UUID().uuidString
        var request = Message("attach", sessionID: id); request.viewportID = viewportID
        relay.send(request)
        scheduleAttachmentTimeout()
    }
    private func scheduleAttachmentTimeout() {
        attachmentTimeout?.cancel()
        let attachment = viewportID
        attachmentTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.viewportID == attachment, !self.ready else { return }
            self.failAttachment("El Mac no envió la pantalla a tiempo. Vuelve a conectar.", reason: "timeout")
        }
    }
    private func failAttachment(_ message: String, reason: String = "invalid") {
        clearHistory(); cancelInput(); ready = false
        sessionNotice = L10n.text(message)
        diagnostic = "AFK connection | \(Date().ISO8601Format()) | viewport | \(reason)"
    }
    func claim() { guard canClaim else { return }; scrollback.returnToLive(); loadingHistory = false; relay.send(Message("claim", sessionID: selected)); objectWillChange.send() }
    func release() { cancelInput(); if owner == credentials?.clientID { relay.send(Message("release", sessionID: selected)) }; owner = "" }
    func leave() { release(); selected = nil; ready = false; clearHistory() }
    func suspend() { active = false; cancelPairing(); unlock.invalidate(); release(); relay.disconnect(); ready = false; sessions = []; clearHistory() }
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
    @discardableResult func input(_ bytes: Data) -> Bool {
        guard canWrite else { return false }
        guard inputBuffer.append(bytes) else {
            release()
            sessionNotice = L10n.text("La entrada es demasiado grande. Se detuvo el envío; revisa la terminal antes de continuar.")
            return false
        }
        return true
    }
    private func sendInput(_ bytes: Data, retry: UInt64?) -> UInt64? {
        guard canClaim, owner == credentials?.clientID else { cancelInput(); return nil }
        if retry == nil { inputSequence += 1 }
        var m = Message("input", sessionID: selected); m.epoch = epoch; m.sequence = retry ?? inputSequence; m.data = bytes.base64EncodedString(); relay.send(m)
        return m.sequence
    }
    func terminate() { guard canTerminate else { return }; relay.send(Message("terminate", sessionID: selected)) }
    func create() { guard canCreate else { return }; var m = Message("create", sessionID: UUID().uuidString); m.name = L10n.format("Terminal %lld", sessions.count + 1); relay.send(m) }
    private func receive(_ m: Message) {
        switch m.type {
        case "welcome": relay.send(Message("list"))
        case "hostOnline": hostAvailable = true; relay.send(Message("list"))
        case "hostOffline": clearHistory(); cancelInput(); hostAvailable = false; ready = false; owner = ""; status = L10n.text("El Mac no está disponible")
        case "sessions":
            hostAvailable = true; sessions = m.sessions ?? []; canCreate = m.canCreate == true
            if let selected, !sessions.contains(where: { $0.id == selected }) {
                clearTerminal(); self.selected = nil; sessionNotice = L10n.text("El Mac retiró el acceso a esta sesión.")
            } else if !canClaim { cancelInput(); owner = "" }
            if let selected, !ready, viewportID == nil, sessionNotice == nil { attach(selected) }

        case "viewport":
            guard m.sessionID == selected, selectedInfo != nil, let id = viewportID, m.viewportID == id else { return }
            guard let bytes = m.data.flatMap({ Data(base64Encoded: $0) }), let sequence = m.sequence,
                  let offset = m.historyOffset, let length = m.historyLength,
                  length <= 8 * 1024 * 1024, offset <= length, bytes.count <= 24 * 1024 else {
                failAttachment("El Mac envió una pantalla no válida. Actualiza ambas apps y vuelve a conectar."); return
            }
            if viewportSequence != sequence {
                guard viewportSequence == nil || sequence > viewportSequence! else { return }
                viewportSequence = sequence; viewportBytes = Data()
            }
            guard offset == UInt64(viewportBytes.count + bytes.count) else {
                failAttachment("El Mac envió una pantalla no válida. Actualiza ambas apps y vuelve a conectar."); return
            }
            viewportBytes.append(bytes)
            if !ready { scheduleAttachmentTimeout() }
            if m.historyComplete == true {
                guard offset == length, let viewport = try? JSONDecoder().decode(TerminalViewport.self, from: viewportBytes),
                      viewport.sequence == sequence, viewport.size.isValid, viewport.rows.count == viewport.size.rows,
                      viewport.rows.allSatisfy({ $0.columns == viewport.size.columns }),
                      (0..<viewport.size.columns).contains(viewport.cursorX), (0..<viewport.size.rows).contains(viewport.cursorY) else {
                    failAttachment("El Mac envió una pantalla no válida. Actualiza ambas apps y vuelve a conectar."); return
                }
                attachmentTimeout?.cancel(); attachmentTimeout = nil
                scrollback.update(viewport); viewportBytes = Data()
                if viewport.historyUnavailable == true {
                    sessionNotice = L10n.text("El historial no está disponible. La pantalla en vivo sigue conectada.")
                }
                inputAcknowledgements = m.inputAcknowledgements == true
                if owner != (m.owner ?? "") || epoch != m.epoch { cancelInput() }
                owner = m.owner ?? ""; if epoch != m.epoch { inputSequence = 0 }; epoch = m.epoch ?? 0
                ready = true; sendSize(); objectWillChange.send()
                if !prefetchedHistory {
                    prefetchedHistory = true
                    sendHistory(scrollback.prefetch())
                }
            }
            var ack = Message("viewportNext", sessionID: selected)
            ack.viewportID = id; ack.sequence = sequence; ack.historyOffset = offset
            viewportAck?.cancel()
            viewportAck = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                guard let self, self.viewportID == id else { return }
                self.relay.send(ack)
            }
        case "historyError":
            guard m.sessionID == selected, let id = viewportID, m.viewportID == id,
                  scrollback.failRequest(m.requestID) else { return }
            loadingHistory = false
            sessionNotice = L10n.text("El historial no está disponible. La pantalla en vivo sigue conectada.")
        case "historyPage":
            guard m.sessionID == selected, let id = viewportID, m.viewportID == id else { return }
            let older = scrollback.pending?.older ?? true
            if scrollback.accept(m) {
                // Keep filling the buffer in the same direction until it holds enough rows.
                sendHistory(scrollback.prefetch(older: older))
                loadingHistory = scrollback.waitingForHistory; objectWillChange.send()
            }
        case "terminalResponse":
            guard canClaim, owner == credentials?.clientID, m.sessionID == selected, m.owner == owner, m.epoch == epoch,
                  let bytes = m.data.flatMap({ Data(base64Encoded: $0) }) else { return }
            inputSequence += 1
            var reply = Message("input", sessionID: selected)
            reply.epoch = epoch; reply.sequence = inputSequence; reply.data = bytes.base64EncodedString()
            relay.send(reply)
        case "snapshot":
            guard m.sessionID == selected, selectedInfo != nil, let events = m.events, feed.reset(events, sequence: m.sequence ?? 0) else { return }
            viewportID = nil; attachmentTimeout?.cancel(); attachmentTimeout = nil
            if owner != (m.owner ?? "") || epoch != m.epoch { cancelInput() }
            inputAcknowledgements = m.inputAcknowledgements == true
            if !inputAcknowledgements { sessionNotice = L10n.text("Actualiza AFK en el Mac para escribir con confirmación de entrega.") }
            owner = m.owner ?? ""; if epoch != m.epoch { inputSequence = 0 }; epoch = m.epoch ?? 0; ready = true; sendSize()
        case "output", "resized":
            guard viewportID == nil, ready, m.sessionID == selected, let sequence = m.sequence, sequence > feed.sequence else { return }
            guard sequence == feed.sequence + 1 else { if let selected { attach(selected) }; return }
            if m.type == "resized", let columns = m.columns, let rows = m.rows {
                feed.sequence = sequence; feed.resize(TerminalSize(columns: columns, rows: rows))
            }
            if let data = m.data.flatMap({ Data(base64Encoded: $0) }) { feed.sequence = sequence; feed.append(data) }
        case "control":
            guard m.sessionID == selected else { return }; if owner != (m.owner ?? "") || epoch != m.epoch { cancelInput() }
            owner = m.owner ?? ""; if epoch != m.epoch { inputSequence = 0 }; epoch = m.epoch ?? 0; sendSize()
        case "inputAck":
            guard m.sessionID == selected, m.epoch == epoch, let sequence = m.sequence else { return }
            inputBuffer.acknowledge(sequence)
        case "exit":
            if m.sessionID == selected {
                cancelInput(); ready = false; owner = ""; sessionNotice = L10n.text("Sesión terminada")
                if let index = sessions.firstIndex(where: { $0.id == selected }) { sessions[index].running = false }
            }
        case "error":
            if let index = sessions.firstIndex(where: { $0.id == m.sessionID }) { sessions[index].closing = false }
            if let sessionID = m.sessionID, sessionID == selected { viewportAck?.cancel(); viewportID = nil; loadingHistory = false; cancelInput(); ready = false; sessionNotice = m.message.map { L10n.text($0) } }
            else { error = m.message.map { L10n.text($0) } }
        default: break
        }
    }
}
