import Foundation

/// Stream ordered edits in fixed windows; retain only bounded, unacknowledged input.
@MainActor
public final class TerminalInputBuffer {
    private struct Flight {
        let data: Data
        let sequence: UInt64
        var sent: ContinuousClock.Instant
        var attempts = 1
    }
    private var bytes = Data()
    private var flights: [Flight] = []
    private var pending: Task<Void, Never>?
    private var generation = UUID()
    private let send: (Data, UInt64?) -> UInt64?
    private let failed: () -> Void

    public init(send: @escaping (Data, UInt64?) -> UInt64?, failed: @escaping () -> Void) {
        self.send = send; self.failed = failed
    }

    @discardableResult public func append(_ data: Data) -> Bool {
        guard bytes.count + flights.reduce(0, { $0 + $1.data.count }) + data.count <= 64 * 1024 else { return false }
        bytes.append(data)
        schedule()
        return true
    }

    public func acknowledge(_ sequence: UInt64) {
        guard flights.contains(where: { $0.sequence == sequence }) else { return }
        flights.removeAll { $0.sequence == sequence }
        // A freed window must not wait for the retry timer to expire.
        pending?.cancel(); pending = nil; generation = UUID()
        schedule()
    }

    public var hasPendingInput: Bool { !bytes.isEmpty || !flights.isEmpty }

    public func cancel() {
        generation = UUID(); pending?.cancel(); pending = nil
        bytes.removeAll(); flights.removeAll()
    }

    private func schedule() {
        guard pending == nil, !bytes.isEmpty || !flights.isEmpty else { return }
        let current = generation
        let delay: Duration = !bytes.isEmpty && flights.count < 4 ? .milliseconds(16) : .milliseconds(100)
        pending = Task { [weak self] in
            // A fixed window, not a debounce: continuous dictation still streams.
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.generation == current else { return }
            self.pending = nil
            self.flush()
            self.schedule()
        }
    }

    private func flush() {
        let current = generation
        if let oldest = flights.first, oldest.sent.duration(to: .now) >= .seconds(1) {
            guard oldest.attempts < 3 else { cancel(); failed(); return }
            // Retransmit the same sequence; the host acknowledges duplicates without applying them.
            let sequence = send(oldest.data, oldest.sequence)
            guard generation == current else { return }
            guard sequence == oldest.sequence else { cancel(); failed(); return }
            if !flights.isEmpty, flights[0].sequence == oldest.sequence {
                flights[0].sent = .now; flights[0].attempts += 1
            }
        }
        guard !bytes.isEmpty, flights.count < 4 else { return }
        let chunk = Data(bytes.prefix(8192))
        let sentSequence = send(chunk, nil)
        guard generation == current else { return }
        guard let sequence = sentSequence else { cancel(); failed(); return }
        bytes.removeFirst(chunk.count)
        flights.append(Flight(data: chunk, sequence: sequence, sent: .now))
    }
}
