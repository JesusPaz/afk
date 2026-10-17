import Foundation

/// A local recording, separate from the bounded network replay. Records preserve ANSI and geometry.
public final class TerminalHistory {
    public struct Entry: Codable, Identifiable {
        public let id: String
        public let name: String
        public let created: Date
        public let directory: URL
    }
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AFK/Session History", isDirectory: true)
    }
    public let entry: Entry
    private let writer: FileHandle
    private let encoder = JSONEncoder()
    public init(root: URL, name: String) throws {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        entry = Entry(id: directory.lastPathComponent, name: name, created: Date(), directory: directory)
        let metadata = directory.appendingPathComponent("session.json")
        try JSONEncoder().encode(entry).write(to: metadata, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
        let output = directory.appendingPathComponent("output.afk")
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        writer = try FileHandle(forWritingTo: output)
    }
    deinit { try? writer.close() }
    public func append(_ event: TerminalEvent) throws {
        guard event.isValid else { throw CocoaError(.fileWriteInvalidFileName) }
        // Bound individual records without limiting the length of the recording.
        if let data = event.data, data.count > 4 * 1024 {
            for start in stride(from: 0, to: data.count, by: 4 * 1024) {
                try append(TerminalEvent(data: data.subdata(in: start..<min(start + 4 * 1024, data.count))))
            }
            return
        }
        let data = try encoder.encode(event)
        var length = UInt32(data.count).bigEndian
        var record = withUnsafeBytes(of: &length) { Data($0) }
        record.append(data)
        try writer.write(contentsOf: record)
    }
    public func synchronize() throws { try writer.synchronize() }
    public static func entries(root: URL) throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .compactMap { directory in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("session.json")),
                      let saved = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
                return Entry(id: directory.lastPathComponent, name: saved.name, created: saved.created, directory: directory)
            }.sorted { $0.created > $1.created }
    }
    public static func delete(_ entry: Entry) throws { try FileManager.default.removeItem(at: entry.directory) }

    public final class Reader {
        private let file: FileHandle
        public let length: UInt64
        public private(set) var offset: UInt64 = 0
        public init(_ entry: Entry) throws {
            file = try FileHandle(forReadingFrom: entry.directory.appendingPathComponent("output.afk"))
            length = try file.seekToEnd(); try file.seek(toOffset: 0)
        }
        deinit { try? file.close() }
        /// Reads a bounded batch, ending only on a complete event boundary.
        public func next(maxBytes: Int = 64 * 1024) throws -> [TerminalEvent] {
            var events: [TerminalEvent] = [], bytes = 0
            while offset < length && bytes < max(1, maxBytes) {
                guard let header = try file.read(upToCount: 4), header.count == 4 else { throw CocoaError(.fileReadCorruptFile) }
                let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard count > 0, count <= 128 * 1024, offset + 4 + UInt64(count) <= length,
                      let data = try file.read(upToCount: Int(count)), data.count == Int(count) else { throw CocoaError(.fileReadCorruptFile) }
                let event = try JSONDecoder().decode(TerminalEvent.self, from: data)
                guard event.isValid else { throw CocoaError(.fileReadCorruptFile) }
                events.append(event); offset += 4 + UInt64(count); bytes += Int(count)
            }
            return events
        }
    }
}
