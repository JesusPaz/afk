import Foundation
import Combine

public struct TerminalSize: Codable, Equatable {
    public let columns: Int
    public let rows: Int
    public init(columns: Int, rows: Int) { self.columns = columns; self.rows = rows }
    public static let initial = TerminalSize(columns: 80, rows: 24)
    public var isValid: Bool { (2...400).contains(columns) && (2...200).contains(rows) }
}

public struct TerminalEvent: Codable, Equatable {
    public var data: Data?
    public var size: TerminalSize?
    public init(data: Data) { self.data = data }
    public init(size: TerminalSize) { self.size = size }
    public var isValid: Bool { (data != nil && size == nil) || (data == nil && size?.isValid == true) }
}

/// Keep ANSI bytes and geometry changes in their original order, from the initial grid.
public struct TerminalReplay {
    private var events: [TerminalEvent] = []
    private var cost = 0
    private var overflowed = false
    public let limit: Int
    public init(limit: Int = 256 * 1024) { self.limit = limit }
    public var snapshot: [TerminalEvent]? { overflowed ? nil : events }
    public mutating func append(_ event: TerminalEvent) {
        guard !overflowed else { return }
        cost += (event.data?.count ?? 0) + 64
        guard event.isValid, cost <= limit else { overflowed = true; events.removeAll(); return }
        events.append(event)
    }
}

@MainActor
public final class TerminalFeed: ObservableObject {
    private var presentation: [TerminalEvent]?
    public private(set) var presentationStart: UInt64?
    public private(set) var followingPresentation = true
    public var onHistoryEdge: ((Bool) -> Void)?
    // Zero probes application-owned history; nonzero returns whether wheel input was accepted.
    public var onApplicationScroll: ((Int) -> Bool)?
    public var onCancelApplicationScroll: (() -> Void)?
    public func present(_ events: [TerminalEvent], sequence: UInt64, start: UInt64, following: Bool) {
        presentation = events; presentationStart = start; followingPresentation = following
        self.sequence = sequence; size = events.compactMap(\.size).last ?? .initial
        for listener in listeners.values { listener(events, true) }
    }
    public func clearPresentation() {
        presentation = nil; presentationStart = nil; followingPresentation = true
        _ = reset([], sequence: 0)
    }
    private var replay = TerminalReplay()
    private var listeners: [UUID: ([TerminalEvent], Bool) -> Void] = [:]
    @Published public private(set) var size = TerminalSize.initial
    public var sequence: UInt64 = 0
    public var snapshot: [TerminalEvent]? { replay.snapshot }
    public let history: TerminalHistory?
    @Published public private(set) var historyError: String?
    public init(history: TerminalHistory? = nil) { self.history = history }
    public func synchronizeHistory() {
        do { try history?.synchronize() } catch { historyError = error.localizedDescription }
    }
    public func append(_ bytes: Data) { append(TerminalEvent(data: bytes)) }
    public func resize(_ size: TerminalSize) { guard size.isValid else { return }; append(TerminalEvent(size: size)) }
    private func append(_ event: TerminalEvent) {
        if let size = event.size { self.size = size }
        if historyError == nil {
            do { try history?.append(event) } catch { historyError = error.localizedDescription }
        }
        replay.append(event)
        for listener in listeners.values { listener([event], false) }
    }
    @discardableResult public func reset(_ events: [TerminalEvent], sequence: UInt64) -> Bool {
        guard events.allSatisfy(\.isValid) else { return false }
        var replay = TerminalReplay()
        for event in events { replay.append(event) }
        guard replay.snapshot != nil else { return false }
        self.sequence = sequence; self.replay = replay
        size = events.compactMap(\.size).last ?? .initial
        for listener in listeners.values { listener(events, true) }
        return true
    }
    public func observe(replayHistory: Bool = false, _ callback: @escaping ([TerminalEvent], Bool) -> Void) -> UUID {
        let id = UUID(); listeners[id] = callback
        if let presentation { callback(presentation, true) }
        else if replayHistory, let history {
            callback([], true)
            do {
                let reader = try TerminalHistory.Reader(history.entry)
                while reader.offset < reader.length { callback(try reader.next(), false) }
            } catch { historyError = error.localizedDescription }
        } else if let snapshot { callback(snapshot, true) }
        return id
    }
    public func remove(_ id: UUID) { listeners.removeValue(forKey: id) }
}
