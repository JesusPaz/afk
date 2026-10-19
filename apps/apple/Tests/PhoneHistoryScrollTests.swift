#if os(iOS)
import UIKit
import XCTest
import AFKCore

private final class HistoryPan: UIPanGestureRecognizer {
    var motion = CGPoint.zero
    override var state: UIGestureRecognizer.State { get { .changed } set {} }
    override func translation(in view: UIView?) -> CGPoint { motion }
}

@MainActor final class PhoneHistoryScrollTests: XCTestCase {
    func testApplicationScrollUsesGestureDeltasInsteadOfRequestingArchivePages() {
        let feed = TerminalFeed()
        let container = TerminalContainer(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let coordinator = TerminalCoordinator(feed: feed, editable: true, input: { _ in }, resize: { _ in })
        coordinator.attach(container)
        defer { coordinator.detach() }
        feed.present([], sequence: 1, start: 0, following: true)
        var lines: [Int] = [], pages = 0
        feed.onApplicationScroll = { lines.append($0); return true }
        feed.onHistoryEdge = { _ in pages += 1 }
        let pan = HistoryPan(); container.terminal.addGestureRecognizer(pan)
        for y in [18, 48, 48, 72, 24] {
            pan.motion = CGPoint(x: 0, y: y)
            coordinator.historyPan(pan)
        }
        XCTAssertEqual(lines, [0, 2, 0, 1, -2])
        XCTAssertEqual(pages, 0)
    }

    func testPageArrivalPreservesVisibleOffsetAfterMomentum() throws {
        let feed = TerminalFeed()
        let scrollback = RemoteScrollback(feed: feed)
        let container = TerminalContainer(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let coordinator = TerminalCoordinator(feed: feed, editable: false, input: { _ in }, resize: { _ in })
        coordinator.attach(container)
        defer { coordinator.detach() }
        scrollback.update(TerminalViewport(size: .initial, rows: (0..<24).map { TerminalRow(ansi: "live \($0)", columns: 80) },
            cursorX: 0, cursorY: 0, cursorVisible: true, applicationCursor: false, bracketedPaste: false,
            keyboardFlags: 0, historyCount: 1000, sequence: 1))
        let request = try XCTUnwrap(scrollback.request(older: true))
        var page = Message("historyPage"); page.requestID = request.requestID
        page.historyStart = 936; page.historyBefore = 1000
        page.historyRows = (936..<1000).map { TerminalRow(ansi: "old \($0)", columns: 80) }
        XCTAssertTrue(scrollback.accept(page))
        let view = container.terminal
        let rowHeight = view.getOptimalFrameSize().height / CGFloat(view.getTerminal().rows)
        // UIKit can advance the visible offset during momentum without updating yDisp.
        view.contentOffset.y = rowHeight * 10
        XCTAssertNotEqual(view.getTerminal().buffer.yDisp, 10)
        let next = try XCTUnwrap(scrollback.request(older: true))
        page.requestID = next.requestID; page.historyStart = 872; page.historyBefore = 936
        page.historyRows = (872..<936).map { TerminalRow(ansi: "old \($0)", columns: 80) }
        XCTAssertTrue(scrollback.accept(page))
        XCTAssertEqual(view.getTerminal().buffer.yDisp, 74)
        XCTAssertEqual(view.contentOffset.y / rowHeight, 74, accuracy: 0.01)
    }

    func testPullingPastFirstRowLoadsOnePageAndKeepsVisibleAnchor() throws {
        let feed = TerminalFeed()
        let scrollback = RemoteScrollback(feed: feed)
        let container = TerminalContainer(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let coordinator = TerminalCoordinator(feed: feed, editable: false, input: { _ in }, resize: { _ in })
        coordinator.attach(container)
        defer { coordinator.detach() }
        var requests: [Message] = []
        feed.onHistoryEdge = { older in if let request = scrollback.request(older: older) { requests.append(request) } }
        scrollback.update(TerminalViewport(size: .initial, rows: (0..<24).map { TerminalRow(ansi: "live \($0)", columns: 80) },
            cursorX: 0, cursorY: 0, cursorVisible: true, applicationCursor: false, bracketedPaste: false,
            keyboardFlags: 0, historyCount: 100_000, sequence: 1))
        XCTAssertTrue(requests.isEmpty)
        let pan = HistoryPan(); container.terminal.addGestureRecognizer(pan)
        pan.motion = CGPoint(x: 0, y: 80)
        coordinator.historyPan(pan); coordinator.historyPan(pan)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].historyBefore, 100_000)
        var page = Message("historyPage"); page.requestID = requests[0].requestID
        page.historyStart = 99_936; page.historyBefore = 100_000
        page.historyRows = (99_936..<100_000).map { TerminalRow(ansi: "old \($0)", columns: 80) }
        XCTAssertTrue(scrollback.accept(page))
        XCTAssertEqual(container.terminal.getTerminal().buffer.yDisp, 64)
        container.terminal.scrollTo(row: 10)
        let before = container.terminal.getTerminal().getLine(row: 0)?.translateToString()
        let next = try XCTUnwrap(scrollback.request(older: true))
        page.requestID = next.requestID; page.historyStart = 99_872; page.historyBefore = 99_936
        page.historyRows = (99_872..<99_936).map { TerminalRow(ansi: "old \($0)", columns: 80) }
        XCTAssertTrue(scrollback.accept(page))
        XCTAssertEqual(container.terminal.getTerminal().getLine(row: 0)?.translateToString(), before)
    }
}
#endif
