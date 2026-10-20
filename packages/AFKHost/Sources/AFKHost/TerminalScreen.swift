#if os(macOS)
import Foundation
import SwiftTerm
import AFKCore

/// The Mac parses the original stream once. Phones receive rendered state, never an arbitrary ANSI suffix.
@MainActor
final class TerminalScreen: @preconcurrency TerminalDelegate {
    private final class SilentDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }
    private(set) var terminal: Terminal!
    let archive: TerminalRowStore?
    private var boundary = 0
    private var promotedRows = 0
    private var cursorVisible = true
    private(set) var error: Error?
    private var capturedResponse: Data?
    var response: ((Data) -> Void)?
    var titleChanged: ((String) -> Void)?
    var directoryChanged: ((String?) -> Void)?
    func setTerminalTitle(source: Terminal, title: String) { titleChanged?(title) }
    func hostCurrentDirectoryUpdated(source: Terminal) { directoryChanged?(source.hostCurrentDirectory) }

    init(directory: URL) {
        do { archive = try TerminalRowStore(directory: directory) }
        catch { archive = nil; self.error = error }
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 24, scrollback: 1000))
    }
    func append(_ data: Data) { terminal.feed(buffer: Array(data)[...]) }
    func resize(_ size: TerminalSize) {
        let sameColumns = terminal.cols == size.columns
        if !sameColumns && !terminal.isCurrentBufferAlternate { archiveReflow(size); promotedRows = 0 }
        let previous = terminal.buffer.totalLinesTrimmed + terminal.buffer.yDisp
        terminal.resize(cols: size.columns, rows: size.rows)
        let current = terminal.buffer.totalLinesTrimmed + terminal.buffer.yDisp
        if sameColumns && !terminal.isCurrentBufferAlternate {
            if current < previous { promotedRows += previous - current }
            else { scrolled(source: terminal, yDisp: terminal.buffer.yDisp) }
        }
        boundary = current
    }
    /// Reflow only the bounded visible screen to find newly hidden text. Reflowing the
    /// entire scrollback would archive old rows again and make resize cost grow with history.
    private func archiveReflow(_ size: TerminalSize) {
        guard error == nil else { return }
        let delegate = SilentDelegate()
        let copy = Terminal(delegate: delegate, options: TerminalOptions(cols: terminal.cols, rows: terminal.rows,
            scrollback: terminal.cols * terminal.rows))
        var bytes = ""
        for row in 0..<terminal.rows {
            if let line = terminal.getLine(row: row) { bytes += render(line, source: terminal, trim: true).ansi }
            if row + 1 < terminal.rows && terminal.getLine(row: row + 1)?.isWrapped != true { bytes += "\r\n" }
        }
        let cursor = terminal.getCursorLocation()
        bytes += "\u{1b}[\(cursor.y + 1);\(min(terminal.cols - 1, cursor.x) + 1)H"
        copy.feed(buffer: Array(bytes.utf8)[...])
        copy.resize(cols: size.columns, rows: size.rows)
        do {
            for row in 0..<copy.buffer.yDisp {
                if let line = copy.getScrollInvariantLine(row: row) { try archive?.append(render(line, source: copy)) }
            }
        } catch { self.error = error }
    }
    func scrolled(source: Terminal, yDisp: Int) {
        guard !source.isCurrentBufferAlternate else { return }
        let end = source.buffer.totalLinesTrimmed + yDisp
        if end < boundary { boundary = 0; promotedRows = 0 }
        while boundary < end {
            if promotedRows > 0 { promotedRows -= 1; boundary += 1; continue }
            if let line = source.getScrollInvariantLine(row: boundary), error == nil {
                do { try archive?.append(render(line, source: source)) } catch { self.error = error }
            }
            boundary += 1
        }
    }
    func bufferActivated(source: Terminal) {
        if !source.isCurrentBufferAlternate { boundary = source.buffer.totalLinesTrimmed + source.buffer.yDisp }
    }
    func showCursor(source: Terminal) { cursorVisible = true }
    func hideCursor(source: Terminal) { cursorVisible = false }
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        if capturedResponse != nil { capturedResponse?.append(contentsOf: data) }
        else { response?(Data(data)) }
    }
    private func scrollEvent(button: Int) -> Data? {
        guard terminal.isCurrentBufferAlternate, terminal.mouseMode != .off else { return nil }
        capturedResponse = Data()
        defer { capturedResponse = nil }
        let flags = terminal.encodeButton(button: button, release: false, shift: false, meta: false, control: false)
        terminal.sendEvent(buttonFlags: flags, x: terminal.cols / 2, y: terminal.rows / 2)
        return capturedResponse
    }
    func snapshot(sequence: UInt64) -> TerminalViewport {
        let cursor = terminal.getCursorLocation()
        var viewport = TerminalViewport(size: TerminalSize(columns: terminal.cols, rows: terminal.rows),
            rows: (0..<terminal.rows).map { row in
                terminal.getLine(row: row).map { render($0, source: terminal, columns: terminal.cols) } ?? TerminalRow(ansi: "", columns: terminal.cols)
            }, cursorX: min(terminal.cols - 1, cursor.x), cursorY: min(terminal.rows - 1, cursor.y), cursorVisible: cursorVisible,
            applicationCursor: terminal.applicationCursor, bracketedPaste: terminal.bracketedPasteMode,
            keyboardFlags: UInt32(terminal.keyboardEnhancementFlags.rawValue), historyCount: error == nil ? archive?.count ?? 0 : 0, sequence: sequence)
        viewport.historyUnavailable = error != nil
        viewport.scrollUp = scrollEvent(button: 4)
        viewport.scrollDown = scrollEvent(button: 5)
        return viewport
    }
    private func render(_ line: BufferLine, source: Terminal, trim: Bool = false, columns: Int? = nil) -> TerminalRow {
        var text = "", previous: Attribute?
        // Alternate-screen lines can retain their old width after narrowing the terminal.
        let count = min(columns ?? line.count, trim ? line.getTrimmedLength() : line.count)
        for column in 0..<count {
            let cell = line[column]
            guard cell.width != 0 else { continue }
            if previous != cell.attribute { text += sgr(cell.attribute); previous = cell.attribute }
            let character = source.getCharacter(for: cell)
            text += character.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) ? " " : String(character)
        }
        return TerminalRow(ansi: text + "\u{1b}[0m", columns: columns ?? line.count)
    }
    private func sgr(_ attribute: Attribute) -> String {
        var codes = ["0"]
        for (flag, code) in [(CharacterStyle.bold, "1"), (.dim, "2"), (.italic, "3"), (.underline, "4"),
                             (.blink, "5"), (.inverse, "7"), (.invisible, "8"), (.crossedOut, "9")] {
            if attribute.style.contains(flag) { codes.append(code) }
        }
        func color(_ color: Attribute.Color, foreground: Bool) -> String {
            let prefix = foreground ? "38" : "48"
            switch color {
            case .ansi256(let code): return "\(prefix);5;\(code)"
            case .trueColor(let r, let g, let b): return "\(prefix);2;\(r);\(g);\(b)"
            case .defaultColor: return foreground ? "39" : "49"
            case .defaultInvertedColor: return foreground ? "39" : "49"
            }
        }
        codes.append(color(attribute.fg, foreground: true)); codes.append(color(attribute.bg, foreground: false))
        return "\u{1b}[" + codes.joined(separator: ";") + "m"
    }
}
#endif
