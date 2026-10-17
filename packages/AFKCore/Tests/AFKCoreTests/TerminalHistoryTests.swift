import XCTest
@testable import AFKCore

final class TerminalHistoryTests: XCTestCase {
    func testRecordingSurvivesReopenBeyondReplayLimitAndDeletesExplicitly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try TerminalHistory(root: root, name: "Test session")
        let bytes = Data(String(repeating: "recorded output\r\n", count: 30_000).utf8)
        try history.append(TerminalEvent(size: TerminalSize(columns: 120, rows: 42)))
        try history.append(TerminalEvent(data: bytes))
        try history.synchronize()
        let entries = try TerminalHistory.entries(root: root)
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.name, "Test session")
        let reader = try TerminalHistory.Reader(entry)
        var restored = Data(), sizes: [TerminalSize] = []
        while reader.offset < reader.length {
            for event in try reader.next() {
                if let data = event.data { restored.append(data) }
                if let size = event.size { sizes.append(size) }
            }
        }
        XCTAssertEqual(restored, bytes)
        XCTAssertEqual(sizes, [TerminalSize(columns: 120, rows: 42)])
        let attributes = try FileManager.default.attributesOfItem(atPath: entry.directory.appendingPathComponent("output.afk").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try TerminalHistory.delete(entry)
        XCTAssertTrue(try TerminalHistory.entries(root: root).isEmpty)
    }
    func testReaderRejectsCorruptLengthWithoutAllocatingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try TerminalHistory(root: root, name: "Corruption")
        try Data([255, 255, 255, 255]).write(to: history.entry.directory.appendingPathComponent("output.afk"))
        let reader = try TerminalHistory.Reader(history.entry)
        XCTAssertThrowsError(try reader.next())
    }
    @MainActor func testMissingRecordingReportsFailureAndLiveOutputContinues() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try TerminalHistory(root: root, name: "Failure")
        let feed = TerminalFeed(history: history)
        // A missing recording is reported during restoration, rather than presented as an empty terminal.
        try TerminalHistory.delete(history.entry)
        var received = Data()
        let observer = feed.observe(replayHistory: true) { events, _ in
            for event in events { if let data = event.data { received.append(data) } }
        }
        defer { feed.remove(observer) }
        XCTAssertNotNil(feed.historyError)
        feed.append(Data("still running".utf8))
        XCTAssertEqual(received, Data("still running".utf8))
    }
}
