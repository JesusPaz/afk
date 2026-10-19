#if os(macOS)
import Foundation
import AFKCore

public enum SessionAccess: String, CaseIterable { case none, readOnly, control }

// Per-session grants are transient; explicitly trusted devices come from the persistent identity store.
@MainActor public final class RemoteAccess {
    private struct Deadline {
        let date: Date
        let uptime: TimeInterval
        func expired(_ date: Date, _ uptime: TimeInterval) -> Bool { date >= self.date || uptime >= self.uptime }
    }
    private struct Grant {
        var control: Deadline?
        var idle: Deadline?
        var close: Deadline?
    }
    private var trustedClients: Set<String> = []
    func setTrustedClients(_ clients: Set<String>) { trustedClients = clients }
    public func isTrusted(_ client: String) -> Bool { trustedClients.contains(client) }
    private var grants: [String: [String: Grant]] = [:]
    private var creators: [String: Deadline] = [:]
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    public static let idleTimeout: TimeInterval = 300
    public init(now: @escaping () -> Date = Date.init, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now; self.uptime = uptime
    }
    private func deadline(_ duration: TimeInterval) -> Deadline { Deadline(date: now().addingTimeInterval(duration), uptime: uptime() + duration) }
    private func valid(_ value: Deadline?) -> Bool { value.map { !$0.expired(now(), uptime()) } ?? false }
    public func level(client: String, session: String) -> SessionAccess {
        if isTrusted(client) { return .control }
        guard let grant = grants[client]?[session] else { return .none }
        return valid(grant.control) && (grant.idle == nil || valid(grant.idle)) ? .control : .readOnly
    }
    public func controlUntil(client: String, session: String) -> Date? {
        guard !isTrusted(client), level(client: client, session: session) == .control else { return nil }
        return grants[client]?[session]?.control?.date
    }
    public func canClose(client: String, session: String) -> Bool { isTrusted(client) || valid(grants[client]?[session]?.close) }
    public func canCreate(client: String) -> Bool { isTrusted(client) || valid(creators[client]) }
    public func createUntil(client: String) -> Date? { !isTrusted(client) && canCreate(client: client) ? creators[client]?.date : nil }
    public func set(client: String, session: String, level: SessionAccess, duration: TimeInterval, allowClose: Bool = false) {
        guard duration.isFinite, duration > 0, duration <= 28800 else { return }
        if level == .none { grants[client]?.removeValue(forKey: session); return }
        grants[client, default: [:]][session] = Grant(control: level == .control ? deadline(duration) : nil,
            idle: nil, close: allowClose ? deadline(duration) : nil)
    }
    public func setCreation(client: String, duration: TimeInterval?) {
        creators.removeValue(forKey: client)
        if let duration, duration.isFinite, duration > 0, duration <= 28800 { creators[client] = deadline(duration) }
    }
    // Explicit creation permission includes access only to the newly created session,
    // ending at the original authorization deadline, never a freshly extended one.
    func created(client: String, session: String) {
        guard canCreate(client: client), let end = creators[client] else { return }
        grants[client, default: [:]][session] = Grant(control: end, idle: nil, close: nil)
    }
    func claimed(client: String, session: String) {
        guard level(client: client, session: session) == .control, grants[client]?[session]?.idle == nil else { return }
        grants[client]?[session]?.idle = deadline(Self.idleTimeout)
    }
    func acceptedInput(client: String, session: String) {
        guard level(client: client, session: session) == .control else { return }
        grants[client]?[session]?.idle = deadline(Self.idleTimeout)
    }
    // Materialize expiry so changing the wall clock or reconnecting cannot revive it.
    func expire() -> [(String, String?)] {
        var expired: [(String, String?)] = []
        for client in Array(grants.keys) {
            for session in Array(grants[client]!.keys) {
                var grant = grants[client]![session]!
                if grant.control != nil && (!valid(grant.control) || (grant.idle != nil && !valid(grant.idle))) {
                    grant.control = nil; grant.idle = nil; expired.append((client, session))
                }
                if grant.close != nil && !valid(grant.close) { grant.close = nil; expired.append((client, session)) }
                grants[client]![session] = grant
            }
        }
        for client in Array(creators.keys) where !canCreate(client: client) { creators.removeValue(forKey: client); expired.append((client, nil)) }
        return expired
    }
    func remove(client: String) { trustedClients.remove(client); grants.removeValue(forKey: client); creators.removeValue(forKey: client) }
    func remove(session: String) { for client in Array(grants.keys) { grants[client]?.removeValue(forKey: session) } }
    func removeAll() { trustedClients.removeAll(); grants.removeAll(); creators.removeAll() }
}

public struct AccessEvent: Codable, Identifiable {
    public enum Kind: String, Codable {
        case connected, disconnected, shared, creationGranted, permissionsRemoved, viewed, controlTaken, denied, expired, revoked, stopped
    }
    public let id: UUID
    public let date: Date
    public let kind: Kind
    public let client: String?
    public let session: String?
}

// Metadata only, bounded across launches; never commands, output, credentials or names.
@MainActor final class AccessHistory {
    private(set) var events: [AccessEvent]
    private let preferences: UserDefaults
    init(preferences: UserDefaults) {
        self.preferences = preferences
        events = preferences.data(forKey: "remoteAccessHistory").flatMap { try? JSONDecoder().decode([AccessEvent].self, from: $0) }.map { Array($0.suffix(200)) } ?? []
    }
    func record(_ kind: AccessEvent.Kind, client: String? = nil, session: String? = nil) {
        let now = Date()
        if kind == .denied, events.suffix(200).contains(where: { $0.kind == kind && $0.client == client && $0.session == session && now.timeIntervalSince($0.date) < 60 }) { return }
        events.append(AccessEvent(id: UUID(), date: now, kind: kind, client: client, session: session))
        events = Array(events.suffix(200))
        if let data = try? JSONEncoder().encode(events) { preferences.set(data, forKey: "remoteAccessHistory") }
    }
}
#endif
