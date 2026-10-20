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
    func testTallLiveScreenStaysAtBottomWhenNewOutputArrives() throws {
        let feed = TerminalFeed()
        let scrollback = RemoteScrollback(feed: feed)
        let container = TerminalContainer(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        container.layoutIfNeeded()
        let coordinator = TerminalCoordinator(feed: feed, editable: false, input: { _ in }, resize: { _ in })
        coordinator.attach(container)
        defer { coordinator.detach() }
        let scroll = try XCTUnwrap(container.terminal.superview as? UIScrollView)
        for sequence in 1...3 {
            scrollback.update(TerminalViewport(size: TerminalSize(columns: 80, rows: 60),
                rows: (0..<60).map { TerminalRow(ansi: "output \(sequence) row \($0)", columns: 80) },
                cursorX: 0, cursorY: 59, cursorVisible: true, applicationCursor: false,
                bracketedPaste: false, keyboardFlags: 0, historyCount: UInt64(1000 + sequence),
                sequence: UInt64(sequence)))
            XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
            XCTAssertEqual(scroll.contentOffset.y, scroll.contentSize.height - scroll.bounds.height,
                           accuracy: 0.1, "Opening and updating a tall screen must show its latest rows")
        }
        container.frame.size.height = 220
        container.setNeedsLayout(); container.layoutIfNeeded()
        XCTAssertEqual(scroll.contentOffset.y, scroll.contentSize.height - scroll.bounds.height,
                       accuracy: 0.1, "Keyboard and layout changes must keep the latest rows visible")
        let request = try XCTUnwrap(scrollback.request(older: true))
        var page = Message("historyPage"); page.requestID = request.requestID
        page.historyStart = 939; page.historyBefore = 1003
        page.historyRows = (939..<1003).map { TerminalRow(ansi: "old \($0)", columns: 80) }
        XCTAssertTrue(scrollback.accept(page))
        scroll.contentOffset.y = 500
        let next = try XCTUnwrap(scrollback.request(older: true))
        page.requestID = next.requestID; page.historyStart = 875; page.historyBefore = 939
        page.historyRows = (875..<939).map { TerminalRow(ansi: "old \($0)", columns: 80) }
        XCTAssertTrue(scrollback.accept(page))
        XCTAssertEqual(scroll.contentOffset.y, 500, accuracy: 0.1,
                       "Loading older history must not shrink the outer viewport and jump upward")
    }

    func testApplicationScrollUsesGestureDeltasInsteadOfRequestingArchivePages() async throws {
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
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertEqual(lines.filter { $0 != 0 }, [2, 1, -2])
        XCTAssertEqual(pages, 0)
    }

    func testLongApplicationGestureKeepsStepsAndFractionalMotion() async throws {
        let feed = TerminalFeed()
        let container = TerminalContainer(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let coordinator = TerminalCoordinator(feed: feed, editable: true, input: { _ in }, resize: { _ in })
        coordinator.attach(container)
        defer { coordinator.detach() }
        feed.present([], sequence: 1, start: 0, following: true)
        var steps: [Int] = []
        feed.onApplicationScroll = { if $0 != 0 { steps.append($0) }; return true }
        let pan = HistoryPan(); container.terminal.addGestureRecognizer(pan)
        pan.motion.y = 250; coordinator.historyPan(pan)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(steps, [8, 2])
        pan.motion.y = 288; coordinator.historyPan(pan)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(steps.reduce(0, +), 12, "Fractional movement must survive between callbacks")
        pan.motion.y = 1200; coordinator.historyPan(pan)
        feed.onCancelApplicationScroll?()
        let count = steps.count
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(steps.count, count, "Revoked control must not leave queued wheel events")
    }

    func testApplicationScrollReversalAndSessionClearCancelQueuedSteps() async throws {
        let feed = TerminalFeed()
        let container = TerminalContainer(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let coordinator = TerminalCoordinator(feed: feed, editable: true, input: { _ in }, resize: { _ in })
        coordinator.attach(container)
        defer { coordinator.detach() }
        feed.present([], sequence: 1, start: 0, following: true)
        var steps: [Int] = []
        feed.onApplicationScroll = { if $0 != 0 { steps.append($0) }; return true }
        let pan = HistoryPan(); container.terminal.addGestureRecognizer(pan)
        pan.motion.y = 480; coordinator.historyPan(pan)
        pan.motion.y = 432; coordinator.historyPan(pan)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(steps, [8, -2], "Reversing drops obsolete forward motion")
        pan.motion.y = 1200; coordinator.historyPan(pan)
        feed.clearPresentation()
        feed.present([], sequence: 1, start: 0, following: true)
        let count = steps.count
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(steps.count, count, "A new session must not inherit queued wheel events")
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
