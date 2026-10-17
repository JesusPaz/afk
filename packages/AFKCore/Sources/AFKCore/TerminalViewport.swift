import Foundation

/// Rendered rows, independent of ANSI parser state. Original output remains in the Mac recording.
public struct TerminalRow: Codable, Equatable {
    public var ansi: String
    public var columns: Int
    public init(ansi: String, columns: Int) { self.ansi = ansi; self.columns = columns }
}

public struct TerminalViewport: Codable, Equatable {
    public var size: TerminalSize
    public var rows: [TerminalRow]
    public var cursorX: Int
    public var cursorY: Int
    public var cursorVisible: Bool
    public var applicationCursor: Bool
    public var bracketedPaste: Bool
    public var keyboardFlags: UInt32
    public var historyCount: UInt64
    public var sequence: UInt64
    public init(size: TerminalSize, rows: [TerminalRow], cursorX: Int, cursorY: Int,
                cursorVisible: Bool, applicationCursor: Bool, bracketedPaste: Bool,
                keyboardFlags: UInt32, historyCount: UInt64, sequence: UInt64) {
        self.size = size; self.rows = rows; self.cursorX = cursorX; self.cursorY = cursorY
        self.cursorVisible = cursorVisible; self.applicationCursor = applicationCursor
        self.bracketedPaste = bracketedPaste; self.keyboardFlags = keyboardFlags
        self.historyCount = historyCount; self.sequence = sequence
    }
}

/// Two append-only files keep both rows and their offsets on disk, not in a growing RAM index.
public final class TerminalRowStore {
    private let rows: FileHandle
    private let index: FileHandle
    public private(set) var count: UInt64 = 0
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        func open(_ name: String) throws -> FileHandle {
            let path = directory.appendingPathComponent(name).path
            guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return try FileHandle(forUpdating: URL(fileURLWithPath: path))
        }
        rows = try open("scrollback.rows"); index = try open("scrollback.index")
    }
    deinit { try? rows.close(); try? index.close() }
    public func append(_ row: TerminalRow) throws {
        let data = try JSONEncoder().encode(row)
        guard data.count <= 64 * 1024 else { throw CocoaError(.fileWriteUnknown) }
        var offset = try rows.seekToEnd().bigEndian
        var size = UInt32(data.count).bigEndian
        try rows.write(contentsOf: withUnsafeBytes(of: &size) { Data($0) } + data)
        try index.seekToEnd()
        try index.write(contentsOf: withUnsafeBytes(of: &offset) { Data($0) })
        count += 1
    }
    public func page(after: UInt64, limit: Int = 64) throws -> (start: UInt64, rows: [TerminalRow]) {
        guard after <= count else { throw CocoaError(.fileReadCorruptFile) }
        var cursor = after, result: [TerminalRow] = [], bytes = 0
        while cursor < count && result.count < min(64, max(1, limit)) && bytes < 64 * 1024 {
            let row = try page(before: cursor + 1, limit: 1).rows[0]
            let size = try JSONEncoder().encode(row).count
            if !result.isEmpty && bytes + size > 64 * 1024 { break }
            result.append(row); bytes += size; cursor += 1
        }
        return (after, result)
    }
    /// A page is bounded in rows and bytes, including when a terminal uses many color changes.
    public func page(before: UInt64, limit: Int = 64) throws -> (start: UInt64, rows: [TerminalRow]) {
        guard before <= count else { throw CocoaError(.fileReadCorruptFile) }
        var cursor = before, result: [TerminalRow] = [], bytes = 0
        while cursor > 0 && result.count < min(64, max(1, limit)) && bytes < 64 * 1024 {
            cursor -= 1
            try index.seek(toOffset: cursor * 8)
            guard let entry = try index.read(upToCount: 8), entry.count == 8 else { throw CocoaError(.fileReadCorruptFile) }
            let offset = entry.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            try rows.seek(toOffset: offset)
            guard let header = try rows.read(upToCount: 4), header.count == 4 else { throw CocoaError(.fileReadCorruptFile) }
            let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length <= 64 * 1024, let data = try rows.read(upToCount: Int(length)), data.count == Int(length) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if !result.isEmpty && bytes + data.count > 64 * 1024 { cursor += 1; break }
            result.append(try JSONDecoder().decode(TerminalRow.self, from: data)); bytes += data.count
        }
        return (cursor, result.reversed())
    }
}
