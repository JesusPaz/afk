#if os(macOS)
import Foundation
import Darwin
import SwiftTerm

/// Nonblocking PTY I/O, serialized with the host's input authority on the main queue.
@MainActor
final class PTYProcess {
    var onData: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?
    private var fd: Int32 = -1
    private var pid: pid_t = -1
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var monitor: DispatchSourceProcess?
    private var pending = Data()

    func start(shell: String, environment: [String]) -> Bool {
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard let child = PseudoTerminalHelpers.fork(andExec: shell, args: [shell, "-l"], env: environment,
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path, desiredWindowSize: &size) else { return false }
        fd = child.masterFd; pid = child.pid
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        readSource.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readAvailable() } }
        let ownedFD = fd
        readSource.setCancelHandler { Darwin.close(ownedFD) }
        reader = readSource; readSource.activate()
        let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exitSource.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.readAvailable()
                var status: Int32 = 0
                _ = waitpid(self.pid, &status, 0)
                self.pid = -1; self.closeIO(); self.onExit?(status)
            }
        }
        monitor = exitSource; exitSource.activate()
        return true
    }
    func resize(columns: Int, rows: Int) -> Bool {
        guard fd >= 0 else { return false }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        return ioctl(fd, TIOCSWINSZ, &size) == 0
    }
    func send(_ data: Data) -> Bool {
        guard fd >= 0 else { return false }
        guard pending.count + data.count <= 64 * 1024 else { terminate(); return false }
        pending.append(data); flush()
        return fd >= 0
    }
    private func flush() {
        guard fd >= 0 else { return }
        while !pending.isEmpty {
            let written = pending.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
            if written > 0 { pending.removeFirst(written); continue }
            if written < 0 && errno == EINTR { continue }
            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if writer == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
                    source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.flush() } }
                    writer = source; source.activate()
                }
                return
            }
            terminate(); return
        }
        writer?.cancel(); writer = nil
    }
    private func readAvailable() {
        guard fd >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        // Bound each turn so high-throughput output cannot starve control messages.
        for _ in 0..<4 {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 { onData?(Data(bytes.prefix(count))); continue }
            if count < 0 && errno == EINTR { continue }
            if count == 0 || (count < 0 && errno == EIO) { closeIO() }
            return
        }
    }
    func terminate() {
        if pid > 0 { _ = kill(pid, SIGTERM) }
        closeIO()
    }
    private func closeIO() {
        reader?.cancel(); reader = nil; writer?.cancel(); writer = nil
        pending.removeAll()
        fd = -1
        if pid < 0 { monitor?.cancel(); monitor = nil }
    }
}
#endif
