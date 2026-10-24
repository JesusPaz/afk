#if os(macOS)
import Foundation
import Combine
import Darwin
import SwiftTerm
import AFKCore

public struct WorkspaceProfile: RawRepresentable, Codable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let personal = Self(rawValue: "personal")
    public static let work = Self(rawValue: "work")
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

@MainActor
public final class HostSession: ObservableObject, Identifiable {
    public let id: String
    @Published public private(set) var userLabel: String?
    @Published public private(set) var reportedTitle: String?
    @Published public private(set) var context: String?
    @Published public internal(set) var groupID: String?
    @Published public internal(set) var profile: WorkspaceProfile = .personal
    @Published public internal(set) var isHidden = false
    @Published public private(set) var closing = false
    @Published public private(set) var inputError: String?
    public var name: String { userLabel ?? shownTitle ?? context ?? "Terminal · " + id.prefix(4).uppercased() }
    // Codex appends " | <directory>" to its title; the context already says where the shell is.
    private var shownTitle: String? {
        guard let title = reportedTitle, let separator = title.range(of: " | ", options: .backwards) else { return reportedTitle }
        let suffix = String(title[separator.upperBound...])
        let home = FileManager.default.homeDirectoryForCurrentUser.lastPathComponent
        guard suffix == context || suffix == home, separator.lowerBound > title.startIndex else { return title }
        return String(title[..<separator.lowerBound])
    }
    private var metadataTask: Task<Void, Never>?
    public let feed: TerminalFeed
    @Published public private(set) var running = true
    @Published public private(set) var lease = ControlLease()
    public var onEvent: ((Message) -> Void)?
    public var onState: (() -> Void)?
    let screen: TerminalScreen?
    private let temporaryScreenDirectory: URL?
    private let process = PTYProcess()
    private var pendingOutput = Data()
    private var outputTask: Task<Void, Never>?
    private var acknowledgedInputs: [UInt64] = []
    private var inputEpoch: UInt64 = 0
    private var localSequence: UInt64 = 0
    private var localSize = TerminalSize.initial
    private var lastRenewal = ProcessInfo.processInfo.systemUptime
    public var info: SessionInfo {
        var value = SessionInfo(id: id, name: name, running: running, owner: lease.owner, epoch: lease.epoch)
        value.context = context; value.closing = closing
        return value
    }
    public func rename(_ label: String?) { userLabel = SessionMetadata.clean(label); onState?() }
    private func metadataChanged() {
        guard metadataTask == nil else { return }
        metadataTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.metadataTask = nil; self?.onState?()
        }
    }

    public init(id: String = UUID().uuidString, name: String = "Shell", history: TerminalHistory? = nil) {
        self.id = id; feed = TerminalFeed(history: history)
        if name != "Shell" && !name.hasPrefix("Terminal ") { userLabel = SessionMetadata.clean(name) }
        let directory = history?.entry.directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("AFK-screen-" + UUID().uuidString)
        temporaryScreenDirectory = history == nil ? directory : nil
        screen = TerminalScreen(directory: directory)
        _ = feed.observe { [weak screen] events, _ in
            for event in events {
                if let data = event.data { screen?.append(data) }
                if let size = event.size { screen?.resize(size) }
            }
        }
        screen?.response = { [weak self] bytes in
            guard let self, self.lease.owner != "local", !self.lease.owner.isEmpty else { return }
            var reply = Message("terminalResponse", sessionID: self.id)
            reply.data = bytes.base64EncodedString(); reply.owner = self.lease.owner; reply.epoch = self.lease.epoch
            self.onEvent?(reply)
        }
        screen?.titleChanged = { [weak self] title in
            guard let self else { return }
            let clean = SessionMetadata.clean(title)
            if clean != self.reportedTitle { self.reportedTitle = clean; self.metadataChanged() }
        }
        screen?.directoryChanged = { [weak self] directory in
            guard let self, let directory, let url = URL(string: directory), url.isFileURL else { return }
            let isHome = url.standardizedFileURL.path == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
            let clean = SessionMetadata.clean(isHome ? "~" : url.lastPathComponent)
            if self.context != clean { self.context = clean; self.metadataChanged() }
        }
        process.onData = { [weak self] in self?.received($0) }
        process.onExit = { [weak self] in self?.exited($0) }
    }
    deinit { if let temporaryScreenDirectory { try? FileManager.default.removeItem(at: temporaryScreenDirectory) } }
    public func start() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("AFK_") && $0.key != "DATABASE_URL" }
        environment["TERM"] = "xterm-256color"; environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "AFK"
        environment.removeValue(forKey: "TERM_PROGRAM_VERSION")
        if !process.start(shell: shell, environment: environment.map { "\($0.key)=\($0.value)" }) { exited(-1) }
    }
    public func claim(_ client: String) {
        guard running, !closing else { return }
        lease.claim(client); localSequence = 0; lastRenewal = ProcessInfo.processInfo.systemUptime; publishControl()
        if client == "local" { applySize(localSize) }
    }
    public func release(_ client: String) { guard lease.owner == client else { return }; lease.release(client); publishControl() }
    public func renew(_ client: String, epoch: UInt64) {
        if lease.owner == client && lease.epoch == epoch { lastRenewal = ProcessInfo.processInfo.systemUptime }
    }
    public func expireControl() {
        if !lease.owner.isEmpty && lease.owner != "local" && ProcessInfo.processInfo.systemUptime - lastRenewal > 30 { release(lease.owner) }
    }
    @discardableResult
    public func input(_ bytes: Data, client: String, epoch: UInt64, sequence: UInt64) -> Bool {
        guard running, !closing, !bytes.isEmpty, bytes.count <= 8192, lease.accept(client: client, epoch: epoch, sequence: sequence) else { return false }
        lastRenewal = ProcessInfo.processInfo.systemUptime
        guard process.send(bytes) else { return false }
        if inputEpoch != epoch { acknowledgedInputs.removeAll(); inputEpoch = epoch }
        acknowledgedInputs.append(sequence)
        if acknowledgedInputs.count > 256 { acknowledgedInputs.removeFirst() }
        return true
    }
    public func acknowledgesInput(client: String, epoch: UInt64, sequence: UInt64) -> Bool {
        running && lease.owner == client && lease.epoch == epoch && inputEpoch == epoch && acknowledgedInputs.contains(sequence)
    }
    public func localResize(_ size: TerminalSize) {
        guard size.isValid else { return }
        localSize = size
        if lease.owner == "local" { applySize(size) }
    }
    public func resize(_ size: TerminalSize, client: String, epoch: UInt64, sequence: UInt64) {
        guard running, size.isValid, lease.accept(client: client, epoch: epoch, sequence: sequence) else { return }
        applySize(size)
    }
    private func applySize(_ size: TerminalSize) {
        guard running, size != feed.size, process.resize(columns: size.columns, rows: size.rows) else { return }
        flushOutput()
        feed.sequence += 1; feed.resize(size)
        var message = Message("resized", sessionID: id)
        message.sequence = feed.sequence; message.columns = size.columns; message.rows = size.rows
        onEvent?(message)
    }
    public func localInput(_ bytes: Data) {
        guard running, !closing, lease.owner == "local" else { return }
        // Reject before sending any part when this paste exceeds the PTY queue.
        guard process.canAccept(bytes.count) else {
            inputError = L10n.text("La entrada es demasiado grande. No se envió; pega un bloque más pequeño.")
            return
        }
        inputError = nil
        for start in stride(from: 0, to: bytes.count, by: 8192) {
            localSequence += 1
            guard input(bytes.subdata(in: start..<min(start + 8192, bytes.count)),
                        client: "local", epoch: lease.epoch, sequence: localSequence) else {
                inputError = L10n.text("No se pudo enviar toda la entrada. Revisa la terminal antes de continuar.")
                return
            }
        }
    }
    public func terminate() {
        guard running, !closing else { return }
        flushOutput()
        feed.synchronizeHistory()
        closing = true; lease.claim(""); publishControl(); process.terminate()
    }
    public func forceClose() { guard running else { return }; closing = true; lease.claim(""); publishControl(); process.terminate(force: true) }
    private func publishControl() {
        var message = Message("control", sessionID: id); message.owner = lease.owner; message.epoch = lease.epoch; onEvent?(message); onState?()
    }
    private func received(_ bytes: Data) {
        if pendingOutput.count + bytes.count > 64 * 1024 { flushOutput() }
        pendingOutput.append(bytes)
        guard outputTask == nil else { return }
        outputTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            self?.flushOutput()
        }
    }
    func flushOutput() {
        outputTask?.cancel(); outputTask = nil
        guard !pendingOutput.isEmpty else { return }
        let bytes = pendingOutput; pendingOutput.removeAll()
        feed.sequence += 1; feed.append(bytes)
        var message = Message("output", sessionID: id); message.sequence = feed.sequence; message.data = bytes.base64EncodedString(); onEvent?(message)
    }
    private func exited(_ status: Int32) {
        flushOutput()
        feed.synchronizeHistory()
        running = false; closing = false; lease.claim("")
        var message = Message("exit", sessionID: id); message.message = "Sesión terminada (\(status))."; onEvent?(message); onState?()
    }
}
#endif
