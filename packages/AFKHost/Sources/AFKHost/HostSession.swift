#if os(macOS)
import Foundation
import Combine
import Darwin
import SwiftTerm
import AFKCore

@MainActor
public final class HostSession: ObservableObject, Identifiable {
    public let id: String
    public let name: String
    public let feed = TerminalFeed()
    @Published public private(set) var running = true
    @Published public private(set) var lease = ControlLease()
    public var onEvent: ((Message) -> Void)?
    public var onState: (() -> Void)?
    private let process = PTYProcess()
    private var pendingOutput = Data()
    private var outputTask: Task<Void, Never>?
    private var acknowledgedInputs: [UInt64] = []
    private var inputEpoch: UInt64 = 0
    private var localSequence: UInt64 = 0
    private var localSize = TerminalSize.initial
    private var lastRenewal = ProcessInfo.processInfo.systemUptime
    public var info: SessionInfo { SessionInfo(id: id, name: name, running: running, owner: lease.owner, epoch: lease.epoch) }

    public init(id: String = UUID().uuidString, name: String = "Shell") {
        self.id = id; self.name = name
        process.onData = { [weak self] in self?.received($0) }
        process.onExit = { [weak self] in self?.exited($0) }
    }
    public func start() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("AFK_") && $0.key != "DATABASE_URL" }
        environment["TERM"] = "xterm-256color"; environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "AFK"
        environment.removeValue(forKey: "TERM_PROGRAM_VERSION")
        if !process.start(shell: shell, environment: environment.map { "\($0.key)=\($0.value)" }) { exited(-1) }
    }
    public func claim(_ client: String) {
        guard running else { return }
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
        guard running, !bytes.isEmpty, bytes.count <= 8192, lease.accept(client: client, epoch: epoch, sequence: sequence) else { return false }
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
        localSequence += 1; input(bytes, client: "local", epoch: lease.epoch, sequence: localSequence)
    }
    public func terminate() {
        guard running else { return }
        flushOutput()
        process.terminate(); running = false; lease.claim(""); publishControl()
    }
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
        running = false; lease.claim("")
        var message = Message("exit", sessionID: id); message.message = "Sesión terminada (\(status))."; onEvent?(message); onState?()
    }
}
#endif
