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
    private var localSequence: UInt64 = 0
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
        if !process.start(shell: shell, environment: environment.map { "\($0.key)=\($0.value)" }) { exited(-1) }
    }
    public func claim(_ client: String) {
        guard running else { return }
        lease.claim(client); localSequence = 0; lastRenewal = ProcessInfo.processInfo.systemUptime; publishControl()
    }
    public func release(_ client: String) { guard lease.owner == client else { return }; lease.release(client); publishControl() }
    public func renew(_ client: String, epoch: UInt64) {
        if lease.owner == client && lease.epoch == epoch { lastRenewal = ProcessInfo.processInfo.systemUptime }
    }
    public func expireControl() {
        if !lease.owner.isEmpty && lease.owner != "local" && ProcessInfo.processInfo.systemUptime - lastRenewal > 30 { release(lease.owner) }
    }
    public func input(_ bytes: Data, client: String, epoch: UInt64, sequence: UInt64) {
        guard running, bytes.count <= 8192, lease.accept(client: client, epoch: epoch, sequence: sequence) else { return }
        lastRenewal = ProcessInfo.processInfo.systemUptime
        process.send(bytes)
    }
    public func localInput(_ bytes: Data) {
        localSequence += 1; input(bytes, client: "local", epoch: lease.epoch, sequence: localSequence)
    }
    public func terminate() {
        guard running else { return }
        process.terminate(); running = false; lease.claim(""); publishControl()
    }
    private func publishControl() {
        var message = Message("control", sessionID: id); message.owner = lease.owner; message.epoch = lease.epoch; onEvent?(message); onState?()
    }
    private func received(_ bytes: Data) {
        feed.sequence += 1; feed.append(bytes)
        var message = Message("output", sessionID: id); message.sequence = feed.sequence; message.data = bytes.base64EncodedString(); onEvent?(message)
    }
    private func exited(_ status: Int32) {
        running = false; lease.claim("")
        var message = Message("exit", sessionID: id); message.message = "Sesión terminada (\(status))."; onEvent?(message); onState?()
    }
}
#endif
