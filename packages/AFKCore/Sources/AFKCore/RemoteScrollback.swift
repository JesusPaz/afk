import Foundation

/// A bounded window into the Mac's immutable row archive. Scrolling, not attachment, requests pages.
@MainActor
public final class RemoteScrollback {
    public let feed: TerminalFeed
    public private(set) var viewport: TerminalViewport?
    public private(set) var rows: [TerminalRow] = []
    public private(set) var start: UInt64 = 0
    public private(set) var end: UInt64 = 0
    public private(set) var browsing = false
    public private(set) var pending: (id: String, cursor: UInt64, older: Bool)?
    public init(feed: TerminalFeed) { self.feed = feed }
    public func clear() {
        viewport = nil; rows = []; start = 0; end = 0; browsing = false; pending = nil
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
        guard let viewport, pending == nil else { return nil }
        if !older && end >= viewport.historyCount {
            returnToLive(); return nil
        }
        let cursor = older ? start : end
        guard !older || cursor > 0 else { return nil }
        browsing = true
        let id = UUID().uuidString
        pending = (id, cursor, older)
        var message = Message("historyPage")
        message.requestID = id
        if older { message.historyBefore = cursor } else { message.historyStart = cursor }
        return message
    }
    @discardableResult public func accept(_ message: Message) -> Bool {
        guard let pending, message.requestID == pending.id,
              let first = message.historyStart, let last = message.historyBefore,
              let page = message.historyRows, first <= last, last - first == UInt64(page.count),
              page.count <= 64, page.allSatisfy({ (2...400).contains($0.columns) }),
              (pending.older ? last == pending.cursor : first == pending.cursor) else { return false }
        self.pending = nil
        if pending.older {
            rows.insert(contentsOf: page, at: 0); start = first
            if rows.count > 256 { rows.removeLast(rows.count - 256) }
            end = start + UInt64(rows.count)
        } else {
            rows.append(contentsOf: page); end = last
            if rows.count > 256 { rows.removeFirst(rows.count - 256) }
            start = end - UInt64(rows.count)
        }
        display(following: false)
        return true
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
