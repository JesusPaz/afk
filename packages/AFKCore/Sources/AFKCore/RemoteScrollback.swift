import Foundation

/// A bounded rendered window with a separate cache of immutable rows for the current attachment.
@MainActor
public final class RemoteScrollback {
    public let feed: TerminalFeed
    public private(set) var viewport: TerminalViewport?
    public private(set) var rows: [TerminalRow] = []
    public private(set) var start: UInt64 = 0
    public private(set) var end: UInt64 = 0
    public private(set) var browsing = false
    public private(set) var pending: (id: String, cursor: UInt64, older: Bool)?
    private var prefetching = false
    private var cache: [UInt64: TerminalRow] = [:]
    private var cacheOrder: [UInt64] = []
    private(set) var cachedBytes = 0
    var cachedRowCount: Int { cache.count }
    public var waitingForHistory: Bool { pending != nil && !prefetching }
    public init(feed: TerminalFeed) { self.feed = feed }
    public func clear() {
        viewport = nil; rows = []; start = 0; end = 0; browsing = false; pending = nil
        cache = [:]; cacheOrder = []; cachedBytes = 0; prefetching = false
        feed.clearPresentation()
    }
    public func update(_ viewport: TerminalViewport) {
        self.viewport = viewport
        if !browsing {
            rows = []; start = viewport.historyCount; end = start
            display(following: true)
        }
    }
    public func returnToLive() {
        guard let viewport else { return }
        pending = nil; browsing = false; rows = []; start = viewport.historyCount; end = start
        display(following: true)
    }
    public func request(older: Bool) -> Message? {
        guard let viewport else { return nil }
        if !older && end >= viewport.historyCount {
            returnToLive(); return nil
        }
        let cursor = older ? start : end
        guard !older || cursor > 0 else { return nil }
        if let pending {
            guard prefetching else { return nil }
            if pending.cursor == cursor && pending.older == older {
                prefetching = false; browsing = true
                return nil
            }
            self.pending = nil
        }
        browsing = true
        let page = cachedPage(cursor: cursor, older: older)
        if !page.isEmpty {
            append(page, first: older ? cursor - UInt64(page.count) : cursor, older: older)
            return nil
        }
        return makeRequest(cursor: cursor, older: older, prefetch: false)
    }
    /// One page ahead; receiving it never moves the visible window or starts another fetch.
    public func prefetch(older: Bool = true) -> Message? {
        guard let viewport, viewport.scrollUp == nil, pending == nil else { return nil }
        let cursor = older ? start : end
        guard older ? cursor > 0 : cursor < viewport.historyCount,
              cachedPage(cursor: cursor, older: older).isEmpty else { return nil }
        return makeRequest(cursor: cursor, older: older, prefetch: true)
    }
    private func makeRequest(cursor: UInt64, older: Bool, prefetch: Bool) -> Message {
        let id = UUID().uuidString
        pending = (id, cursor, older); prefetching = prefetch
        var message = Message("historyPage")
        message.requestID = id
        if older { message.historyBefore = cursor } else { message.historyStart = cursor }
        return message
    }
    private func cachedPage(cursor: UInt64, older: Bool) -> [TerminalRow] {
        var result: [TerminalRow] = []
        var index = cursor
        while result.count < 64 {
            if older { guard index > 0 else { break }; index -= 1 }
            guard let row = cache[index] else { break }
            result.append(row)
            if !older { index += 1 }
        }
        return older ? result.reversed() : result
    }
    @discardableResult public func accept(_ message: Message) -> Bool {
        guard let pending, message.requestID == pending.id,
              let first = message.historyStart, let last = message.historyBefore,
              let page = message.historyRows, first <= last, last - first == UInt64(page.count),
              page.count <= 64, page.allSatisfy({ (2...400).contains($0.columns) }),
              (pending.older ? last == pending.cursor : first == pending.cursor) else { return false }
        self.pending = nil
        for (offset, row) in page.enumerated() {
            let index = first + UInt64(offset)
            if cache[index] == nil {
                cache[index] = row; cacheOrder.append(index)
                cachedBytes += row.ansi.utf8.count + 16
            }
        }
        var evicted = 0
        while cachedBytes > 1024 * 1024 || cache.count > 4096 {
            let index = cacheOrder[evicted]; evicted += 1
            if let row = cache.removeValue(forKey: index) { cachedBytes -= row.ansi.utf8.count + 16 }
        }
        cacheOrder.removeFirst(evicted)
        if !prefetching { append(page, first: first, older: pending.older) }
        prefetching = false
        return true
    }
    private func append(_ page: [TerminalRow], first: UInt64, older: Bool) {
        if older {
            rows.insert(contentsOf: page, at: 0); start = first
            if rows.count > 256 { rows.removeLast(rows.count - 256) }
            end = start + UInt64(rows.count)
        } else {
            rows.append(contentsOf: page); end = first + UInt64(page.count)
            if rows.count > 256 { rows.removeFirst(rows.count - 256) }
            start = end - UInt64(rows.count)
        }
        display(following: false)
    }
    private func display(following: Bool) {
        guard let viewport else { return }
        let includesLive = end == viewport.historyCount
        let visibleRows = rows + (includesLive ? viewport.rows : [])
        let columns = max(viewport.size.columns, visibleRows.map(\.columns).max() ?? 2)
        let size = TerminalSize(columns: columns, rows: viewport.size.rows)
        var ansi = "\u{1b}[?7l"
        for (index, row) in visibleRows.enumerated() {
            ansi += "\r" + row.ansi
            if index + 1 < visibleRows.count { ansi += "\r\n" }
        }
        if includesLive {
            ansi += "\u{1b}[\(viewport.cursorY + 1);\(viewport.cursorX + 1)H"
            ansi += "\u{1b}[?1\(viewport.applicationCursor ? "h" : "l")"
            ansi += "\u{1b}[?2004\(viewport.bracketedPaste ? "h" : "l")"
            ansi += "\u{1b}[>\(viewport.keyboardFlags)u"
        }
        ansi += "\u{1b}[?25\(includesLive && !browsing && viewport.cursorVisible ? "h" : "l")"
        feed.present([TerminalEvent(size: size), TerminalEvent(data: Data(ansi.utf8))],
                     sequence: viewport.sequence, start: start, following: following)
    }
}
