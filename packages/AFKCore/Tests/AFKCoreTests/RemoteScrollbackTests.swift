import XCTest
@testable import AFKCore

@MainActor final class RemoteScrollbackTests: XCTestCase {
    private func viewport(count: UInt64, sequence: UInt64 = 1) -> TerminalViewport {
        TerminalViewport(size: .initial, rows: Array(repeating: TerminalRow(ansi: "current", columns: 80), count: 24),
            cursorX: 0, cursorY: 0, cursorVisible: true, applicationCursor: false, bracketedPaste: false,
            keyboardFlags: 0, historyCount: count, sequence: sequence)
    }
    private func page(_ request: Message, first: UInt64, last: UInt64) -> Message {
        var page = Message("historyPage"); page.requestID = request.requestID
        page.historyStart = first; page.historyBefore = last
        page.historyRows = (first..<last).map { TerminalRow(ansi: "row \($0)", columns: 80) }
        return page
    }
    func testAttachLoadsOnlyScreenAndScrollRequestsBoundedPages() throws {
        let state = RemoteScrollback(feed: TerminalFeed())
        state.update(viewport(count: 1_000_000))
        XCTAssertNil(state.pending); XCTAssertTrue(state.rows.isEmpty); XCTAssertFalse(state.browsing)
        for n in 0..<10 {
            let end = UInt64(1_000_000 - 64 * n)
            let request = try XCTUnwrap(state.request(older: true))
            XCTAssertEqual(request.historyBefore, end)
            XCTAssertNil(state.request(older: true), "Only one request may be outstanding")
            XCTAssertTrue(state.accept(page(request, first: end - 64, last: end)))
            XCTAssertLessThanOrEqual(state.rows.count, 256)
        }
        let start = state.start, rows = state.rows
        state.update(viewport(count: 1_000_100, sequence: 2))
        XCTAssertEqual(state.start, start); XCTAssertEqual(state.rows, rows)
        let next = try XCTUnwrap(state.request(older: false))
        XCTAssertEqual(next.historyStart, state.end)
        let end = state.end
        XCTAssertTrue(state.accept(page(next, first: end, last: end + 64)))
        XCTAssertLessThanOrEqual(state.rows.count, 256)
    }
    func testStalePagesCannotPopulateNewSessionAndReturningToLiveNeedsNoReplay() throws {
        let state = RemoteScrollback(feed: TerminalFeed())
        state.update(viewport(count: 64))
        let request = try XCTUnwrap(state.request(older: true))
        XCTAssertTrue(state.accept(page(request, first: 0, last: 64)))
        XCTAssertNil(state.request(older: true))
        XCTAssertNil(state.request(older: false)); XCTAssertFalse(state.browsing)
        state.clear(); state.update(viewport(count: 3))
        XCTAssertFalse(state.accept(page(request, first: 0, last: 64)))
        XCTAssertTrue(state.rows.isEmpty)
    }
    func testDiskIndexReadsBothDirectionsWithoutLoadingFullHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TerminalRowStore(directory: root)
        for i in 0..<10_000 { try store.append(TerminalRow(ansi: "line \(i)", columns: 80)) }
        let tail = try store.page(before: store.count)
        XCTAssertEqual(tail.start, 9936); XCTAssertEqual(tail.rows.count, 64)
        XCTAssertEqual(tail.rows.last?.ansi, "line 9999")
        let next = try store.page(after: 20)
        XCTAssertEqual(next.start, 20); XCTAssertEqual(next.rows.first?.ansi, "line 20")
        XCTAssertEqual(next.rows.count, 64)
        XCTAssertThrowsError(try store.page(before: 10_001))
    }
}
