import Foundation

@MainActor
public final class TerminalFeed {
    private var replay = ReplayBuffer()
    private var listeners: [UUID: (Data, Bool) -> Void] = [:]
    public var sequence: UInt64 = 0
    public var snapshot: Data? { replay.snapshot }
    public init() {}
    public func append(_ bytes: Data) {
        replay.append(bytes)
        for listener in listeners.values { listener(bytes, false) }
    }
    public func reset(_ bytes: Data, sequence: UInt64) {
        self.sequence = sequence; replay = ReplayBuffer(); replay.append(bytes)
        for listener in listeners.values { listener(bytes, true) }
    }
    public func observe(_ callback: @escaping (Data, Bool) -> Void) -> UUID {
        let id = UUID(); listeners[id] = callback
        if let snapshot { callback(snapshot, true) }
        return id
    }
    public func remove(_ id: UUID) { listeners.removeValue(forKey: id) }
}
