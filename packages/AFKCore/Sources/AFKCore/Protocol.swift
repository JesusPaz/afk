import Foundation

public struct SessionInfo: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var running: Bool
    public var owner: String
    public var epoch: UInt64
    public var canControl: Bool?
    public var canTerminate: Bool?
    public var controlExpiresAt: Date?
    public init(id: String, name: String, running: Bool, owner: String, epoch: UInt64) {
        self.id = id; self.name = name; self.running = running; self.owner = owner; self.epoch = epoch
    }
}

public struct Message: Codable {
    public var type: String
    public var clientID: String?
    public var sessionID: String?
    public var epoch: UInt64?
    public var sequence: UInt64?
    public var data: String?
    public var events: [TerminalEvent]?
    public var historyID: String?
    public var historyOffset: UInt64?
    public var historyLength: UInt64?
    public var historyComplete: Bool?
    public var columns: Int?
    public var rows: Int?
    public var owner: String?
    public var name: String?
    public var sessions: [SessionInfo]?
    public var inputAcknowledgements: Bool?
    public var canCreate: Bool?
    public var message: String?
    public init(_ type: String, sessionID: String? = nil) { self.type = type; self.sessionID = sessionID }
}

public struct HostIdentity: Codable { public let id: String; public let code: String; public let name: String }
public struct Pairing: Codable { public let secret: String; public let expiresAt: String }
public struct ClientCredentials: Codable {
    public let clientID: String
    public let token: String
    public let host: HostIdentity
}
public struct PairedClient: Codable, Identifiable { public let id: String; public let name: String }

public struct ControlLease {
    public private(set) var owner: String = "local"
    public private(set) var epoch: UInt64 = 1
    private var sequence: UInt64 = 0
    public init() {}
    public mutating func claim(_ client: String) {
        owner = client; epoch += 1; sequence = 0
    }
    public mutating func release(_ client: String) {
        guard owner == client else { return }; claim("")
    }
    public mutating func accept(client: String, epoch: UInt64, sequence: UInt64) -> Bool {
        guard !client.isEmpty, client == owner, epoch == self.epoch, sequence > self.sequence else { return false }
        self.sequence = sequence; return true
    }
}
