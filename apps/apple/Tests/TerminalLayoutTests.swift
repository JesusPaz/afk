#if os(macOS)
import AppKit
import XCTest
import AFKCore

final class TerminalLayoutTests: XCTestCase {
    @MainActor func testPrependingHistoryPreservesVisibleRowWhileOutputContinues() throws {
        _ = NSApplication.shared
        let feed = TerminalFeed()
        let history = RemoteScrollback(feed: feed)
        let container = TerminalContainer(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let coordinator = TerminalCoordinator(feed: feed, editable: false, input: { _ in }, resize: { _ in })
        coordinator.attach(container)
        defer { coordinator.detach() }
        var viewport = TerminalViewport(size: .initial, rows: (0..<24).map { TerminalRow(ansi: "live \($0)", columns: 80) },
            cursorX: 0, cursorY: 0, cursorVisible: true, applicationCursor: false, bracketedPaste: false,
            keyboardFlags: 0, historyCount: 1000, sequence: 1)
        history.update(viewport)
        func olderPage() throws {
            let request = try XCTUnwrap(history.request(older: true))
            let end = try XCTUnwrap(request.historyBefore)
            var page = Message("historyPage"); page.requestID = request.requestID
            page.historyStart = end - 64; page.historyBefore = end
            page.historyRows = ((end - 64)..<end).map { TerminalRow(ansi: "old \($0)", columns: 80) }
            XCTAssertTrue(history.accept(page))
        }
        try olderPage()
        container.terminal.scrollTo(row: 10)
        let before = container.terminal.getTerminal().getLine(row: 0)?.translateToString()
        try olderPage()
        XCTAssertEqual(container.terminal.getTerminal().getLine(row: 0)?.translateToString(), before)
        XCTAssertEqual(container.terminal.getTerminal().buffer.yDisp, 74)
        viewport.historyCount += 100; viewport.sequence += 1
        history.update(viewport)
        XCTAssertEqual(container.terminal.getTerminal().getLine(row: 0)?.translateToString(), before)
    }

    @MainActor func testReattachAfterReplayOverflowRestoresAlternateScreenWithoutSendingInput() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try TerminalHistory(root: root, name: "Codex regression")
        let feed = TerminalFeed(history: history)
        let first = TerminalContainer(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        var inputs: [Data] = []
        let coordinator = TerminalCoordinator(feed: feed, editable: true, input: { inputs.append($0) }, resize: { _ in })
        coordinator.attach(first)
        feed.resize(TerminalSize(columns: 110, rows: 36))
        for _ in 0..<40 { feed.append(Data(String(repeating: "background output\r\n", count: 500).utf8)) }
        XCTAssertNil(feed.snapshot, "Reproduce the old 256 KiB replay failure")
        feed.append(Data("\u{1b}[?1049h\u{1b}[2J\u{1b}[3;5HCodex still running\u{1b}[6n".utf8))
        let terminal = first.terminal.getTerminal()
        let before = (0..<36).map { terminal.getLine(row: $0)?.translateToString() }
        let cursor = terminal.getCursorLocation()
        coordinator.detach()
        inputs.removeAll()
        // Recreate the native view, as switching sessions used to do (also covers reopening the window).
        let restored = TerminalContainer(frame: first.frame)
        let replacement = TerminalCoordinator(feed: feed, editable: true, input: { inputs.append($0) }, resize: { _ in })
        replacement.attach(restored)
        defer { replacement.detach() }
        let actual = restored.terminal.getTerminal()
        XCTAssertEqual(actual.cols, 110); XCTAssertEqual(actual.rows, 36)
        XCTAssertEqual((0..<36).map { actual.getLine(row: $0)?.translateToString() }, before)
        XCTAssertEqual(actual.getCursorLocation().x, cursor.x)
        XCTAssertEqual(actual.getCursorLocation().y, cursor.y)
        XCTAssertTrue(inputs.isEmpty, "Restoration must not send historical terminal queries to the live shell")
        feed.append(Data(" live".utf8))
        XCTAssertTrue(actual.getLine(row: 2)?.translateToString().contains("Codex still running live") == true)
    }
    @MainActor func testSharedPanelPreview() throws {
        guard let path = ProcessInfo.processInfo.environment["AFK_PANEL_PREVIEW"] else { return }
        _ = NSApplication.shared
        let container = TerminalContainer(frame: CGRect(x: 0, y: 0, width: 1000, height: 760))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(AFKStyle.terminalBackground).cgColor
        container.observing = true
        let feed = TerminalFeed()
        let coordinator = TerminalCoordinator(feed: feed, editable: false, input: { _ in }, resize: { _ in })
        coordinator.attach(container)
        defer { coordinator.detach() }
        feed.resize(TerminalSize(columns: 39, rows: 30))
        feed.append(Data("~ /proyectos/afk\r\n\r\n$ echo Hola desde el iPhone\r\nHola desde el iPhone\r\n\r\n$ ".utf8))
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(container.bitmapImageRepForCachingDisplay(in: container.bounds))
        container.cacheDisplay(in: container.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
    @MainActor func testViewportDoesNotReflowObserverAndReplayRestoresGrid() {
        _ = NSApplication.shared
        let feed = TerminalFeed()
        let container = TerminalContainer(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let coordinator = TerminalCoordinator(feed: feed, editable: false, input: { _ in }, resize: { _ in })
        container.observing = true
        coordinator.attach(container)
        defer { coordinator.detach() }
        feed.append(Data(("\u{1b}[31m" + String(repeating: "texto largo café 🌱 ", count: 10) + "\u{1b}[0m\r\n").utf8))
        feed.resize(TerminalSize(columns: 39, rows: 30))
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(container.terminal.getTerminal().cols, 39)
        XCTAssertEqual(container.terminal.getTerminal().rows, 30)
        container.frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(container.terminal.getTerminal().cols, 39)
        let panel = container.terminal.superview!
        XCTAssertEqual(panel.frame.midX, 600, accuracy: 1)
        XCTAssertEqual(panel.frame.minY, 24)
        XCTAssertEqual(container.terminal.frame.minY, 44)
        container.observing = false
        XCTAssertEqual(panel.frame.minX, 0)
        XCTAssertEqual(panel.frame.minY, 0)
        XCTAssertEqual(container.terminal.frame.minY, 0)
        feed.resize(TerminalSize(columns: 120, rows: 42))
        feed.append(Data("\u{1b}[2;3Hcursor\r\n".utf8))
        let terminal = container.terminal.getTerminal()
        let before = (0..<42).map { terminal.getLine(row: $0)?.translateToString() }
        let cursor = terminal.getCursorLocation()
        let events = feed.snapshot!
        XCTAssertTrue(feed.reset(events, sequence: 3))
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(container.terminal.getTerminal().cols, 120)
        XCTAssertEqual(container.terminal.getTerminal().rows, 42)
        XCTAssertEqual((0..<42).map { terminal.getLine(row: $0)?.translateToString() }, before)
        XCTAssertEqual(terminal.getCursorLocation().x, cursor.x)
        XCTAssertEqual(terminal.getCursorLocation().y, cursor.y)
    }
}
#endif
