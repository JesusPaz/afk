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
    @Published public private(set) var groups: [SessionGroup] = []
    private struct Organization: Codable {
        var version = 1
        var groups: [SessionGroup] = []
        var sessions: [String: Metadata] = [:]
    }
    private struct Metadata: Codable {
        var label: String?
        var groupID: String?
        var hidden: Bool
    }
    private var organization = Organization()
    private var removalRequested: Set<String> = []
    private var deletedGroupPositions: [String: Int] = [:]
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
    private struct ViewTransfer {
        let id: String
        let session: String
        var data: Data?
        var offset = 0
        var sequence: UInt64 = 0
    }
    private var views: [String: ViewTransfer] = [:]
    private let history: AccessHistory
    public var accessEvents: [AccessEvent] { history.events }
    private let historyDirectory: URL?
    private let preferences: UserDefaults
    private var restoredConnection = false
    private var base: URL?
    private var secret: HostSecret?
    private var timer: Timer?
    private let pairingUnlock = LocalDeviceUnlock()
    private let trustUnlock = LocalDeviceUnlock()
    private var pairingGeneration = UUID()
    private var lockObserver: NSObjectProtocol?
    private var statusSubscription: AnyCancellable?

    public init(preferences: UserDefaults = .standard, access: RemoteAccess? = nil, historyDirectory: URL? = nil) {
        self.historyDirectory = historyDirectory
        self.preferences = preferences
        if let data = preferences.data(forKey: "sessionOrganization"),
           let saved = try? JSONDecoder().decode(Organization.self, from: data), saved.version == 1 {
            organization = saved; groups = saved.groups
        }
        self.access = access ?? RemoteAccess(); history = AccessHistory(preferences: preferences)
        remoteAccessPaused = preferences.bool(forKey: "remoteAccessPaused")
        relay.onPairingEnded = { [weak self] in self?.pairing = nil }
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.cancelPairing(); self?.trustUnlock.invalidate(); self?.accessRevision += 1
            }
        }
        relay.onMessage = { [weak self] in self?.receive($0) }
        relay.onDisconnect = { [weak self] in
            guard let self else { return }
            self.views.removeAll()
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
        guard sessions.filter({ $0.running }).count < 8 else { error = L10n.text("El POC permite hasta ocho sesiones."); return nil }
        let recording: TerminalHistory?
        do { recording = try historyDirectory.map { try TerminalHistory(root: $0, name: String(name.prefix(60))) } }
        catch { self.error = error.localizedDescription; return nil }
        let session = HostSession(id: id, name: String(name.prefix(60)), history: recording)
        session.onEvent = { [weak self] in self?.forward($0) }
        if let metadata = organization.sessions[id] {
            session.rename(metadata.label)
            session.groupID = groups.contains(where: { $0.id == metadata.groupID }) ? metadata.groupID : nil
            session.isHidden = metadata.hidden
        }
        session.onState = { [weak self, weak session] in
            guard let self, let session else { return }
            if !session.running && self.removalRequested.contains(session.id) { self.removeEnded(id: session.id) }
            else { self.persistOrganization(); self.publishSessions() }
        }
        sessions.append(session); persistOrganization(); session.start(); publishSessions(); return session
    }
    private func persistOrganization() {
        for session in sessions {
            do { try session.feed.history?.updateMetadata(name: session.name, context: session.context,
                group: groups.first(where: { $0.id == session.groupID }), sessionID: session.id) }
            catch { self.error = error.localizedDescription }
        }
        organization.groups = groups
        organization.sessions = Dictionary(uniqueKeysWithValues: sessions.map {
            ($0.id, Metadata(label: $0.userLabel, groupID: $0.groupID, hidden: $0.isHidden))
        })
        if let data = try? JSONEncoder().encode(organization) { preferences.set(data, forKey: "sessionOrganization") }
    }
    private func organizationChanged() { persistOrganization(); publishSessions() }
    public func renameSession(id: String, label: String?) { sessions.first(where: { $0.id == id })?.rename(label) }
    public func setHidden(id: String, hidden: Bool) {
        sessions.first(where: { $0.id == id })?.isHidden = hidden; organizationChanged()
    }
    public func moveSession(id: String, groupID: String?) {
        guard groupID == nil || groups.contains(where: { $0.id == groupID }) else { return }
        sessions.first(where: { $0.id == id })?.groupID = groupID; organizationChanged()
    }
    @discardableResult public func createGroup(name: String, symbol: String = "folder", color: String = "blue") -> SessionGroup? {
        guard let name = SessionMetadata.clean(name), groups.count < 64 else { return nil }
        let group = SessionGroup(name: name, symbol: SessionGroup.symbols.contains(symbol) ? symbol : "folder",
                                 color: SessionGroup.colors.contains(color) ? color : "blue")
        groups.append(group); organizationChanged(); return group
    }
    public func updateGroup(_ group: SessionGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }), let name = SessionMetadata.clean(group.name) else { return }
        groups[index] = SessionGroup(id: group.id, name: name, symbol: SessionGroup.symbols.contains(group.symbol) ? group.symbol : "folder",
                                    color: SessionGroup.colors.contains(group.color) ? group.color : "blue")
        organizationChanged()
    }
    public func deleteGroup(id: String) {
        if let index = groups.firstIndex(where: { $0.id == id }) { deletedGroupPositions = [id: index] }
        groups.removeAll { $0.id == id }
        for session in sessions where session.groupID == id { session.groupID = nil }
        organizationChanged()
    }
    public func restoreGroup(_ group: SessionGroup, sessionIDs: [String]) {
        guard !groups.contains(where: { $0.id == group.id }), groups.count < 64 else { return }
        let index = min(groups.count, deletedGroupPositions.removeValue(forKey: group.id) ?? groups.count)
        groups.insert(group, at: index)
        for session in sessions where session.groupID == nil && sessionIDs.contains(session.id) { session.groupID = group.id }
        organizationChanged()
    }
    public func reorderGroup(id: String, offset: Int) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let destination = max(0, min(groups.count - 1, index + offset))
        let group = groups.remove(at: index); groups.insert(group, at: destination); organizationChanged()
    }
    public func reorderSession(id: String, offset: Int) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let peers = sessions.indices.filter { sessions[$0].groupID == sessions[index].groupID && sessions[$0].isHidden == sessions[index].isHidden }
        guard let position = peers.firstIndex(of: index) else { return }
        let destination = peers[max(0, min(peers.count - 1, position + offset))]
        sessions.swapAt(index, destination); organizationChanged()
    }
    public func closeAndRemove(id: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        removalRequested.insert(id)
        if session.running { session.terminate() } else { removeEnded(id: id) }
    }
    public func forceClose(id: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        removalRequested.insert(id); session.forceClose()
    }
    public func removeEnded(id: String) {
        guard let session = sessions.first(where: { $0.id == id }), !session.running else { return }
        session.flushOutput(); session.feed.synchronizeHistory(); persistOrganization()
        views = views.filter { $0.value.session != id }; access.remove(session: id)
        session.onState = nil; session.onEvent = nil
        sessions.removeAll { $0.id == id }; removalRequested.remove(id); organizationChanged()
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
            base = url; secret = identity; host = h; error = nil; restoreTrustedAccess()
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
            clients = relay.clients; restoreTrustedAccess()
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
            clients = relay.clients; restoreTrustedAccess()
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
        trustUnlock.invalidate()
        cancelPairing()
        accessRevision += 1
        remoteAccessPaused = true; preferences.set(true, forKey: "remoteAccessPaused")
        access.removeAll(); relay.disconnect(); pairing = nil
        do { try relay.clearFullAccess() } catch { self.error = error.localizedDescription }
        do { try relay.cancelInvitation() } catch { self.error = error.localizedDescription }
        record(.stopped)
    }
    public func shutdown() { trustUnlock.invalidate(); accessRevision += 1; relay.disconnect(); sessions.forEach { $0.forceClose() }; timer?.invalidate() }
    public func stopRemoteAccess() { pause() }
    public func revokeAllDevices() {
        pause()
        do { try relay.revokeAll(); clients = relay.clients; record(.revoked) }
        catch { self.error = error.localizedDescription }
    }
    public var hardwareIdentity: Bool { relay.trust?.state.identity.isHardwareBacked == true }
    public func supportsTrustedAccess(_ client: String) -> Bool {
        hardwareIdentity && relay.trust?.state.peers.first(where: { $0.id == client })?.biometricIdentity == true
    }
    private func restoreTrustedAccess() {
        let peers = relay.trust?.state.peers ?? []
        access.setTrustedClients(Set(peers.filter { $0.fullAccess == true && $0.biometricIdentity == true && hardwareIdentity }.map(\.id)))
    }
    public func setTrustedAccess(_ client: String, enabled: Bool) async {
        let revision = accessRevision
        do {
            if enabled { try await trustUnlock.require() }
            guard accessRevision == revision else { return }
            try relay.setFullAccess(client, enabled: enabled)
            accessRevision += 1
            access.remove(client: client)
            if !enabled { releaseControl(client) }
            restoreTrustedAccess()
            record(enabled ? .shared : .permissionsRemoved, client: client); publishSessions()
        } catch { self.error = error.localizedDescription }
    }
    public func upgradeIdentity(server: String) async {
        let revision = accessRevision
        do {
            try await trustUnlock.require()
            guard accessRevision == revision else { return }
            accessRevision += 1; access.removeAll()
            try relay.upgradeIdentity()
            clients = relay.clients
            await connect(server: server)
        } catch { self.error = error.localizedDescription }
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
        let order = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($0.element.id, $0.offset) })
        return sessions.sorted {
            ($0.groupID.flatMap { order[$0] } ?? groups.count) < ($1.groupID.flatMap { order[$0] } ?? groups.count)
        }.compactMap { session in
            guard access.level(client: client, session: session.id) != .none else { return nil }
            var info = session.info
            info.group = groups.first(where: { $0.id == session.groupID })
            info.canRemove = access.canClose(client: client, session: session.id)
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
            if message.type == "terminalResponse", message.owner != client { continue }
            if let view = views[client], view.session == session, ["output", "resized"].contains(message.type) {
                if view.data == nil, let hostSession = sessions.first(where: { $0.id == session }) { sendViewport(client: client, session: hostSession) }
                continue
            }
            var m = message; m.clientID = client; relay.send(m)
        }
    }
    private func deny(_ client: String, session: String? = nil) {
        views.removeValue(forKey: client)
        record(.denied, client: client, session: session)
        sendError("El Mac no ha autorizado esta operación.", client: client)
        publishSessions(to: client)
    }
    private func sendError(_ text: String, client: String, session: String? = nil) {
        var m = Message("error", sessionID: session); m.clientID = client; m.message = text; relay.send(m)
    }
    private func sendViewport(client: String, session: HostSession) {
        do {
            guard let screen = session.screen, screen.error == nil else { throw CocoaError(.fileReadUnknown) }
            let data = try JSONEncoder().encode(screen.snapshot(sequence: session.feed.sequence))
            guard data.count <= 8 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            views[client]?.data = data; views[client]?.offset = 0; views[client]?.sequence = session.feed.sequence
            sendViewportPart(client: client)
        } catch { sendError("No se pudo leer el historial completo del Mac.", client: client, session: session.id) }
    }
    private func sendViewportPart(client: String) {
        guard var view = views[client], let data = view.data,
              let session = sessions.first(where: { $0.id == view.session }) else { return }
        let end = min(data.count, view.offset + 24 * 1024)
        var reply = Message("viewport", sessionID: view.session)
        reply.viewportID = view.id; reply.clientID = client; reply.sequence = view.sequence
        reply.data = data.subdata(in: view.offset..<end).base64EncodedString()
        reply.historyOffset = UInt64(end); reply.historyLength = UInt64(data.count); reply.historyComplete = end == data.count
        reply.owner = session.lease.owner; reply.epoch = session.lease.epoch; reply.inputAcknowledgements = true
        view.offset = end; views[client] = view
        relay.send(reply)
    }
    func receive(_ m: Message) {
        guard let client = m.clientID else { return }
        if m.type == "clientConnected" {
            connectedClients.insert(client); clients = relay.clients; record(.connected, client: client); publishSessions(to: client); return
        }
        if m.type == "clientDisconnected" { views.removeValue(forKey: client); connectedClients.remove(client); releaseControl(client); record(.disconnected, client: client); return }
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
        if ["terminate", "closeAndRemove"].contains(m.type), !access.canClose(client: client, session: session.id) { deny(client, session: session.id); return }
        switch m.type {
        case "viewportNext":
            guard let view = views[client], view.session == session.id, view.id == m.viewportID,
                  view.sequence == m.sequence, UInt64(view.offset) == m.historyOffset else { return }
            if let data = view.data, view.offset == data.count {
                views[client]?.data = nil
                if session.feed.sequence > view.sequence { sendViewport(client: client, session: session) }
            } else { sendViewportPart(client: client) }
        case "historyPage":
            guard let view = views[client], view.session == session.id, view.id == m.viewportID,
                  let request = m.requestID, UUID(uuidString: request) != nil else { return }
            do {
                guard let screen = session.screen, screen.error == nil else { throw CocoaError(.fileReadUnknown) }
                let page: (start: UInt64, rows: [TerminalRow])
                if let before = m.historyBefore { page = try screen.archive.page(before: before) }
                else if let after = m.historyStart { page = try screen.archive.page(after: after) }
                else { return }
                var reply = Message("historyPage", sessionID: session.id)
                reply.clientID = client; reply.viewportID = view.id; reply.requestID = request
                reply.historyStart = page.start; reply.historyBefore = page.start + UInt64(page.rows.count); reply.historyRows = page.rows
                relay.send(reply)
            } catch { sendError("No se pudo leer el historial completo del Mac.", client: client, session: session.id) }
        case "attach":
            views.removeValue(forKey: client)
            if let id = m.viewportID {
                guard UUID(uuidString: id) != nil else { return }
                session.flushOutput()
                views[client] = ViewTransfer(id: id, session: session.id)
                record(.viewed, client: client, session: session.id)
                sendViewport(client: client, session: session)
                return
            }
            session.flushOutput()
            record(.viewed, client: client, session: session.id)
            guard let bytes = session.feed.snapshot else {
                sendError("El historial supera el límite del POC. La sesión continúa en el Mac; abre una nueva para compartirla.", client: client, session: session.id); return
            }
            var reply = Message("snapshot", sessionID: session.id); reply.clientID = client; reply.events = bytes; reply.sequence = session.feed.sequence
            reply.inputAcknowledgements = true
            reply.owner = session.lease.owner; reply.epoch = session.lease.epoch; reply.columns = session.feed.size.columns; reply.rows = session.feed.size.rows; relay.send(reply)
        case "claim":
            access.claimed(client: client, session: session.id); session.claim(client); record(.controlTaken, client: client, session: session.id)
        case "release": session.release(client)
        case "renew": session.renew(client, epoch: m.epoch ?? 0)
        case "input":
            guard let data = m.data.flatMap({ Data(base64Encoded: $0) }), let epoch = m.epoch, let sequence = m.sequence else { return }
            if session.input(data, client: client, epoch: epoch, sequence: sequence) { access.acceptedInput(client: client, session: session.id) }
            if session.acknowledgesInput(client: client, epoch: epoch, sequence: sequence) {
                var ack = Message("inputAck", sessionID: session.id)
                ack.clientID = client; ack.epoch = epoch; ack.sequence = sequence; relay.send(ack)
            }
        case "resize":
            guard let columns = m.columns, let rows = m.rows, let epoch = m.epoch, let sequence = m.sequence else { return }
            session.resize(TerminalSize(columns: columns, rows: rows), client: client, epoch: epoch, sequence: sequence)
        case "terminate": session.terminate()
        case "closeAndRemove": closeAndRemove(id: session.id)
        default: break
        }
    }
}
#endif
