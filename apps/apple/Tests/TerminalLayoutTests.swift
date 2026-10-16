#if os(macOS)
import AppKit
import XCTest
import AFKCore

final class TerminalLayoutTests: XCTestCase {
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
