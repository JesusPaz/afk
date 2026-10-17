#if os(macOS)
import XCTest
import SwiftTerm
import AFKCore
@testable import AFKHost

private final class SilentTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

@MainActor final class TerminalScreenTests: XCTestCase {
    func testCurrentScreenDoesNotDependOnTransferringOldOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = try TerminalScreen(directory: root)
        for i in 0..<20_000 { screen.append(Data("row \(i) café 🌱\r\n".utf8)) }
        screen.append(Data("\u{1b}[?1049h\u{1b}[2J\u{1b}[3;5H\u{1b}[31mCodex café 🌱\u{1b}[0m".utf8))
        let viewport = screen.snapshot(sequence: 123)
        XCTAssertGreaterThan(viewport.historyCount, 19_000)
        XCTAssertEqual(viewport.rows.count, 24)
        XCTAssertLessThan(try JSONEncoder().encode(viewport).count, 12 * 1024)
        XCTAssertTrue(viewport.rows[2].ansi.contains("Codex café 🌱"))
        let first = try screen.archive.page(before: 64)
        XCTAssertEqual(first.start, 0)
        XCTAssertTrue(first.rows[0].ansi.contains("row 0 café 🌱"))
        let previous = try screen.archive.page(before: viewport.historyCount)
        XCTAssertEqual(previous.start + UInt64(previous.rows.count), viewport.historyCount)
        XCTAssertNil(screen.error)
    }

    func testNarrowingArchivesVisibleTextWithoutReplayingOldHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = try TerminalScreen(directory: root)
        for i in 0..<1000 { screen.append(Data("old \(i)\r\n".utf8)) }
        screen.append(Data("\u{1b}[2J\u{1b}[H".utf8))
        for i in 0..<20 { screen.append(Data(("unique-\(i)-" + String(repeating: "x", count: 55) + "\r\n").utf8)) }
        let before = screen.archive.count
        screen.resize(TerminalSize(columns: 10, rows: 24))
        XCTAssertGreaterThan(screen.archive.count, before)
        XCTAssertLessThan(screen.archive.count - before, 200)
        let page = try screen.archive.page(after: before)
        XCTAssertTrue(page.rows.contains { $0.ansi.contains("unique-0-") })
        XCTAssertNil(screen.error)
    }

    func testGrowingThenShrinkingHeightDoesNotDuplicatePromotedHistoryRows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = try TerminalScreen(directory: root)
        for i in 0..<100 { screen.append(Data("line \(i)\r\n".utf8)) }
        let count = screen.archive.count
        screen.resize(TerminalSize(columns: 80, rows: 40))
        screen.resize(TerminalSize(columns: 80, rows: 24))
        XCTAssertEqual(screen.archive.count, count)
        screen.append(Data("new line\r\n".utf8))
        XCTAssertEqual(screen.archive.count, count + 1)
    }

    func testRenderedStateMatchesAfterUnicodeSplitResizeAndAlternateScreen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = try TerminalScreen(directory: root)
        let display = Terminal(delegate: SilentTerminalDelegate(), options: TerminalOptions(cols: 80, rows: 24))
        let feed = TerminalFeed()
        let scrollback = RemoteScrollback(feed: feed)
        _ = feed.observe { events, reset in
            if reset { display.resetToInitialState() }
            for event in events {
                if let size = event.size { display.resize(cols: size.columns, rows: size.rows) }
                if let data = event.data { display.feed(buffer: Array(data)[...]) }
            }
        }
        let samples = ["normal café 🌱\r\n", "\u{1b}[?1049h\u{1b}[2J\u{1b}[4;6H\u{1b}[38;2;9;80;210mwide 界 é", "\u{1b}[?1049l"]
        for (sequence, sample) in samples.enumerated() {
            for byte in sample.utf8 { screen.append(Data([byte])) }
            screen.resize(TerminalSize(columns: 92, rows: 31))
            let snapshot = screen.snapshot(sequence: UInt64(sequence))
            scrollback.update(snapshot)
            for row in 0..<31 {
                XCTAssertEqual(display.getLine(row: row)?.translateToString().replacingOccurrences(of: "\0", with: " "),
                               screen.terminal.getLine(row: row)?.translateToString().replacingOccurrences(of: "\0", with: " "))
                for column in 0..<92 {
                    let actual = try XCTUnwrap(display.getCharData(col: column, row: row))
                    let expected = try XCTUnwrap(screen.terminal.getCharData(col: column, row: row))
                    XCTAssertEqual(actual.attribute, expected.attribute)
                    XCTAssertEqual(String(display.getCharacter(for: actual)).replacingOccurrences(of: "\0", with: " "),
                                   String(screen.terminal.getCharacter(for: expected)).replacingOccurrences(of: "\0", with: " "))
                }
            }
            XCTAssertEqual(display.getCursorLocation().x, snapshot.cursorX)
            XCTAssertEqual(display.getCursorLocation().y, snapshot.cursorY)
        }
    }
}
#endif
