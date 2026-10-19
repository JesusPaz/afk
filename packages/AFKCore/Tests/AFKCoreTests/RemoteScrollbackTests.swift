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
        let end = state.end
        XCTAssertNil(state.request(older: false), "Recently visited rows come from cache")
        XCTAssertEqual(state.end, end + 64)
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
    func testPrefetchDoesNotRenderAndScrollUsesItWithoutNetwork() throws {
        let state = RemoteScrollback(feed: TerminalFeed())
        state.update(viewport(count: 1000))
        let request = try XCTUnwrap(state.prefetch())
        XCTAssertFalse(state.waitingForHistory)
        XCTAssertTrue(state.accept(page(request, first: 936, last: 1000)))
        XCTAssertFalse(state.browsing); XCTAssertTrue(state.rows.isEmpty)
        XCTAssertNil(state.request(older: true))
        XCTAssertEqual(state.start, 936); XCTAssertEqual(state.rows.count, 64)
        state.returnToLive()
        XCTAssertNil(state.request(older: true))
        XCTAssertEqual(state.start, 936)
    }
    func testScrollPromotesInflightPrefetchAndRejectsStaleResponseAfterClear() throws {
        let state = RemoteScrollback(feed: TerminalFeed())
        state.update(viewport(count: 1000))
        let request = try XCTUnwrap(state.prefetch())
        XCTAssertNil(state.request(older: true)); XCTAssertTrue(state.waitingForHistory)
        XCTAssertTrue(state.accept(page(request, first: 936, last: 1000)))
        XCTAssertEqual(state.start, 936)
        let next = try XCTUnwrap(state.prefetch())
        state.clear(); state.update(viewport(count: 1000))
        XCTAssertFalse(state.accept(page(next, first: 872, last: 936)))
        XCTAssertEqual(state.cachedRowCount, 0)
    }
    func testLiveOutputDuringPrefetchDoesNotJoinNoncontiguousRows() throws {
        let state = RemoteScrollback(feed: TerminalFeed())
        state.update(viewport(count: 1000))
        let old = try XCTUnwrap(state.prefetch())
        state.update(viewport(count: 1010, sequence: 2))
        let current = try XCTUnwrap(state.request(older: true))
        XCTAssertEqual(current.historyBefore, 1010)
        XCTAssertFalse(state.accept(page(old, first: 936, last: 1000)))
        XCTAssertTrue(state.accept(page(current, first: 946, last: 1010)))
        XCTAssertEqual(state.end, 1010)
    }
    func testApplicationOwnedHistoryIsNotPrefetched() {
        let state = RemoteScrollback(feed: TerminalFeed())
        var screen = viewport(count: 1000)
        screen.scrollUp = Data([1]); screen.scrollDown = Data([2])
        state.update(screen)
        XCTAssertNil(state.prefetch())
    }
    func testCacheRemainsBoundedAcrossLongHistory() throws {
        let state = RemoteScrollback(feed: TerminalFeed())
        state.update(viewport(count: 100_000))
        for n in 0..<1600 {
            let end = UInt64(100_000 - 64 * n)
            if end == 0 { break }
            let request = try XCTUnwrap(state.request(older: true))
            var reply = page(request, first: end > 64 ? end - 64 : 0, last: end)
            reply.historyRows = reply.historyRows?.map { TerminalRow(ansi: String(repeating: "x", count: 900), columns: $0.columns) }
            XCTAssertTrue(state.accept(reply))
            XCTAssertLessThanOrEqual(state.cachedRowCount, 4096)
            XCTAssertLessThanOrEqual(state.cachedBytes, 1024 * 1024)
            XCTAssertLessThanOrEqual(state.rows.count, 256)
            if end <= 64 { break }
        }
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
