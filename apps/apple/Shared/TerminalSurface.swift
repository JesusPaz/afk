import SwiftUI
import SwiftTerm
import AFKCore

#if os(macOS)
typealias PlatformView = NSView

final class FileDropTerminalView: TerminalView {
    var acceptsFileInput: (() -> Bool)?
    var fileInput: ((String) -> Void)?

    func droppedPaths(_ pasteboard: NSPasteboard) -> String? {
        guard acceptsFileInput?() == true,
              let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return nil }
        var paths: [String] = []
        for url in urls {
            let path = url.path
            // Terminal controls are interpreted before the shell can honor quoting.
            guard url.isFileURL, !path.isEmpty,
                  !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            paths.append("'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'")
        }
        let text = paths.joined(separator: " ") + " "
        guard text.utf8.count <= 16 * 1024 else { return nil }
        return text
    }

    @discardableResult func receiveFiles(_ pasteboard: NSPasteboard) -> Bool {
        guard let text = droppedPaths(pasteboard), let fileInput else { return false }
        fileInput(text)
        window?.makeFirstResponder(self)
        return true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedPaths(sender.draggingPasteboard) == nil ? [] : .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { droppedPaths(sender.draggingPasteboard) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { receiveFiles(sender.draggingPasteboard) }
}

private final class TerminalStage: NSView {
    override var isFlipped: Bool { true }
}
#else
typealias PlatformView = UIView
#endif

/// The renderer keeps the authoritative grid. Only the surrounding viewport proposes sizes.
@MainActor
final class TerminalContainer: PlatformView {
    let terminal: TerminalView
    var viewportChanged: ((TerminalSize) -> Void)?
    private var cell = CGSize.zero
    private var extraWidth: CGFloat = 0
    #if os(macOS)
    private let scroll = NSScrollView()
    private let stage = TerminalStage()
    private let panel = TerminalStage()
    private let caption = NSTextField(labelWithString: L10n.text("Vista compartida"))
    private let deviceIcon = NSImageView()
    var observing = false { didSet { arrangePanel() } }
    override var isFlipped: Bool { true }
    #else
    private let scroll = UIScrollView()
    #endif

    override init(frame: CGRect) {
        #if os(macOS)
        let fileTerminal = FileDropTerminalView(frame: .zero, font: AFKStyle.terminalFont)
        fileTerminal.registerForDraggedTypes([.fileURL])
        terminal = fileTerminal
        #else
        terminal = TerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: AFKStyle.terminalFontSize, weight: .regular))
        #endif
        super.init(frame: frame)
        terminal.nativeBackgroundColor = .init(AFKStyle.terminalBackground)
        terminal.nativeForegroundColor = .init(AFKStyle.terminalForeground)
        // Measure the library's actual cell metrics before any session data is rendered.
        terminal.resize(cols: 80, rows: 24)
        let first = terminal.getOptimalFrameSize().size
        terminal.resize(cols: 81, rows: 24)
        cell = CGSize(width: terminal.getOptimalFrameSize().width - first.width, height: first.height / 24)
        extraWidth = first.width - 80 * cell.width
        terminal.resize(cols: 80, rows: 24)
        terminal.getTerminal().changeScrollback(10_000)
        addSubview(scroll)
        #if os(macOS)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = stage
        stage.addSubview(panel)
        panel.addSubview(terminal)
        panel.addSubview(caption)
        panel.addSubview(deviceIcon)
        panel.wantsLayer = true
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.textColor = NSColor(AFKStyle.terminalForeground).withAlphaComponent(0.8)
        deviceIcon.image = NSImage(systemSymbolName: "rectangle.portrait", accessibilityDescription: L10n.text("Vista estrecha"))
        deviceIcon.contentTintColor = caption.textColor
        #else
        scroll.addSubview(terminal)
        scroll.contentInsetAdjustmentBehavior = .never
        #endif
        fitRenderer()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func fitRenderer() {
        var frame = terminal.getOptimalFrameSize()
        // Avoid floating-point truncation losing a column during native layout.
        frame.size.width += 0.01; frame.size.height += 0.01
        terminal.frame = frame
        #if os(macOS)
        arrangePanel()
        #else
        terminal.setNeedsLayout(); terminal.layoutIfNeeded()
        scroll.contentSize = frame.size
        #endif
    }
    #if os(iOS)
    var followingLatest = false
    func revealLatestRows() {
        // An observer can receive a Mac grid taller than the phone. SwiftTerm's
        // own scroll position does not move this outer viewport.
        scroll.contentOffset.y = max(0, scroll.contentSize.height - scroll.bounds.height)
    }
    #endif
    #if os(macOS)
    private func arrangePanel() {
        let size = terminal.frame.size
        let framed = observing && size.width + 80 < bounds.width
        let inset: CGFloat = framed ? 16 : 0
        let header: CGFloat = framed ? 44 : 0
        let top: CGFloat = framed ? 24 : 0
        let panelSize = CGSize(width: size.width + inset * 2, height: size.height + header + inset)
        stage.frame = CGRect(x: 0, y: 0, width: max(bounds.width, panelSize.width), height: max(bounds.height, panelSize.height + top * 2))
        panel.frame = CGRect(x: framed ? floor((stage.bounds.width - panelSize.width) / 2) : 0,
                             y: top, width: panelSize.width, height: panelSize.height)
        terminal.setFrameOrigin(CGPoint(x: inset, y: header))
        panel.layer?.cornerRadius = framed ? 18 : 0
        panel.layer?.borderWidth = framed ? 1 : 0
        panel.layer?.borderColor = NSColor(AFKStyle.terminalForeground).withAlphaComponent(0.18).cgColor
        panel.layer?.backgroundColor = NSColor(AFKStyle.terminalBackground).cgColor
        caption.isHidden = !framed; deviceIcon.isHidden = !framed
        deviceIcon.frame = CGRect(x: 16, y: 14, width: 14, height: 16)
        caption.frame = CGRect(x: 38, y: 13, width: max(0, panelSize.width - 54), height: 18)
    }
    #endif
    private func layoutViewport() {
        scroll.frame = bounds
        #if os(macOS)
        arrangePanel()
        #else
        if followingLatest { revealLatestRows() }
        #endif
        guard cell.width > 0, cell.height > 0, bounds.width > extraWidth, bounds.height > 0 else { return }
        let columns = min(400, max(2, Int((bounds.width - extraWidth) / cell.width)))
        let rows = min(200, max(2, Int(bounds.height / cell.height)))
        viewportChanged?(TerminalSize(columns: columns, rows: rows))
    }
    #if os(macOS)
    override func layout() { super.layout(); layoutViewport() }
    #else
    override func layoutSubviews() { super.layoutSubviews(); layoutViewport() }
    #endif
}

@MainActor
final class TerminalCoordinator: NSObject, @preconcurrency TerminalViewDelegate {
    let feed: TerminalFeed
    var input: (Data) -> Void
    var resize: (TerminalSize) -> Void
    var editable: Bool
    var observation: UUID?
    private var replaying = false
    private var attaching = false
    var active = true { didSet { if !active { cancelApplicationScroll() } } }
    private var presentationStart: UInt64?
    private var scrollTranslation: CGFloat = 0
    private var applicationScrollSteps = 0
    private var applicationScrollTask: Task<Void, Never>?
    private func cancelApplicationScroll() {
        applicationScrollTask?.cancel(); applicationScrollTask = nil; applicationScrollSteps = 0
    }
    private func queueApplicationScroll(_ lines: Int) {
        if lines != 0 && (lines > 0) != (applicationScrollSteps > 0) { applicationScrollSteps = 0 }
        applicationScrollSteps = max(-64, min(64, applicationScrollSteps + lines))
        guard applicationScrollTask == nil, applicationScrollSteps != 0 else { return }
        drainApplicationScroll()
        applicationScrollTask = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard let self else { return }
                guard self.active, self.applicationScrollSteps != 0 else {
                    self.applicationScrollTask = nil; return
                }
                self.drainApplicationScroll()
            }
        }
    }
    private func drainApplicationScroll() {
        let steps = max(-8, min(8, applicationScrollSteps))
        applicationScrollSteps -= steps
        if feed.onApplicationScroll?(steps) != true { cancelApplicationScroll() }
    }
    private var proposed: TerminalSize?
    private var pending: DispatchWorkItem?
    init(feed: TerminalFeed, editable: Bool, input: @escaping (Data) -> Void, resize: @escaping (TerminalSize) -> Void) {
        self.feed = feed; self.input = input; self.editable = editable; self.resize = resize
    }
    func attach(_ container: TerminalContainer) {
        let view = container.terminal
        view.terminalDelegate = self
        feed.onCancelApplicationScroll = { [weak self] in self?.cancelApplicationScroll() }
        #if os(macOS)
        if let fileTerminal = view as? FileDropTerminalView {
            fileTerminal.acceptsFileInput = { [weak self] in
                guard let self else { return false }
                return self.active && self.editable && !self.replaying && !self.attaching && !self.feed.isRestoringHistory
            }
            fileTerminal.fileInput = { [weak self, weak view] text in
                guard let self, let view else { return }
                let paste = view.getTerminal().bracketedPasteMode ? "\u{1b}[200~" + text + "\u{1b}[201~" : text
                self.send(source: view, data: Array(paste.utf8)[...])
            }
        }
        #endif
        #if os(iOS)
        view.alwaysBounceVertical = true
        view.panGestureRecognizer.addTarget(self, action: #selector(historyPan(_:)))
        #endif
        container.viewportChanged = { [weak self] size in
            guard let self, size != self.proposed else { return }
            self.proposed = size; self.pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.resize(size) }
            self.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }
        attaching = true
        defer { attaching = false }
        let restoreHistory = true
        observation = feed.observe(replayHistory: restoreHistory) { [weak self, weak container] events, reset in
            guard let self, let container else { return }
            let view = container.terminal
            if self.feed.presentationStart == nil { self.cancelApplicationScroll() }
            #if os(iOS)
            container.followingLatest = self.feed.presentationStart != nil && self.feed.followingPresentation
            // UIKit momentum can move the visible viewport without advancing SwiftTerm's yDisp.
            let rowHeight = view.getOptimalFrameSize().height / CGFloat(view.getTerminal().rows)
            let lastTop = max(0, Int((view.contentSize.height / rowHeight).rounded()) - view.getTerminal().rows)
            let visibleTop = min(lastTop, Int((max(0, view.contentOffset.y) + 0.01) / rowHeight))
            #else
            let visibleTop = max(0, view.getTerminal().buffer.yDisp)
            #endif
            let previousTop = self.presentationStart.map { $0 + UInt64(visibleTop) }
            self.replaying = reset
            if reset {
                view.getTerminal().resetToInitialState()
                #if os(macOS)
                view.resize(cols: 80, rows: 24); container.fitRenderer()
                #endif
            }
            for event in events {
                if let size = event.size {
                    view.resize(cols: size.columns, rows: size.rows); container.fitRenderer()
                }
                if let data = event.data { view.feed(byteArray: Array(data)[...]) }
            }
            if let start = self.feed.presentationStart {
                self.presentationStart = start
                if self.feed.followingPresentation {
                    view.scroll(toPosition: 1)
                    #if os(iOS)
                    container.revealLatestRows()
                    #endif
                }
                else if let previousTop {
                    view.scrollTo(row: Int(previousTop > start ? previousTop - start : 0))
                    #if os(iOS)
                    // SwiftTerm leaves the offset to UIKit while a drag is active; a new page
                    // must still shift that offset to keep the same archived row under the finger.
                    view.contentOffset.y = CGFloat(view.getTerminal().buffer.yDisp) * rowHeight
                    #endif
                }
            }
            self.replaying = false
        }
    }
    func detach() { active = false; cancelApplicationScroll(); feed.onCancelApplicationScroll = nil; pending?.cancel(); if let observation { feed.remove(observation) } }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { if active && editable && !replaying && !attaching && !feed.isRestoringHistory { input(Data(data)) } }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {
        guard !replaying, !attaching, feed.presentationStart != nil else { return }
        if position <= 0.15 { feed.onHistoryEdge?(true) }
        else if position >= 0.85 { feed.onHistoryEdge?(false) }
    }
    #if os(iOS)
    @objc func historyPan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { scrollTranslation = 0; cancelApplicationScroll() }
        if gesture.state == .cancelled || gesture.state == .failed { cancelApplicationScroll(); return }
        guard !replaying, !attaching, (gesture.state == .changed || gesture.state == .ended),
              let view = gesture.view as? TerminalView, feed.presentationStart != nil else { return }
        let motion = gesture.translation(in: view)
        guard abs(motion.y) > abs(motion.x), abs(motion.y) > 12 else { return }
        let lines = Int((motion.y - scrollTranslation) / 24)
        if feed.onApplicationScroll?(0) == true {
            scrollTranslation += CGFloat(lines) * 24
            queueApplicationScroll(lines)
            return
        }
        if motion.y > 0 && view.contentOffset.y < 40 { feed.onHistoryEdge?(true) }
        if motion.y < 0 && view.contentOffset.y + view.bounds.height >= view.contentSize.height - 40 { feed.onHistoryEdge?(false) }
    }
    #endif
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func bell(source: TerminalView) {}
}

#if os(macOS)
struct TerminalSurface: NSViewRepresentable {
    let feed: TerminalFeed
    let editable: Bool
    let input: (Data) -> Void
    let resize: (TerminalSize) -> Void
    var active = true
    func makeCoordinator() -> TerminalCoordinator { TerminalCoordinator(feed: feed, editable: editable, input: input, resize: resize) }
    func makeNSView(context: Context) -> TerminalContainer {
        let view = TerminalContainer(frame: .zero)
        view.observing = !editable
        context.coordinator.attach(view)
        context.coordinator.active = active
        if active { DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            if coordinator?.active == true { view.window?.makeFirstResponder(view.terminal) }
        } }
        return view
    }
    func updateNSView(_ view: TerminalContainer, context: Context) {
        let gainedControl = active && (!context.coordinator.active || (editable && !context.coordinator.editable))
        context.coordinator.active = active
        if !active, view.window?.firstResponder === view.terminal { view.window?.makeFirstResponder(nil) }
        view.observing = !editable
        context.coordinator.editable = editable
        context.coordinator.input = input; context.coordinator.resize = resize
        if gainedControl { DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            if coordinator?.active == true { view.window?.makeFirstResponder(view.terminal) }
        } }
    }
    static func dismantleNSView(_ view: TerminalContainer, coordinator: TerminalCoordinator) { coordinator.detach() }
}
#else
struct TerminalSurface: UIViewRepresentable {
    let feed: TerminalFeed
    let editable: Bool
    let input: (Data) -> Void
    let resize: (TerminalSize) -> Void
    var active = true
    func makeCoordinator() -> TerminalCoordinator { TerminalCoordinator(feed: feed, editable: editable, input: input, resize: resize) }
    func makeUIView(context: Context) -> TerminalContainer {
        let view = TerminalContainer(frame: .zero)
        context.coordinator.active = active
        context.coordinator.attach(view); return view
    }
    func updateUIView(_ view: TerminalContainer, context: Context) {
        context.coordinator.active = active
        context.coordinator.editable = editable; context.coordinator.input = input; context.coordinator.resize = resize
        if (!active || !editable) && view.terminal.isFirstResponder { _ = view.terminal.resignFirstResponder() }
    }
    static func dismantleUIView(_ view: TerminalContainer, coordinator: TerminalCoordinator) { coordinator.detach() }
}
#endif

#if os(macOS)
struct HistoryRecordingStatus: View {
    @ObservedObject var feed: TerminalFeed
    var body: some View {
        if let error = feed.historyError {
            Label(L10n.text("No se está guardando el historial") + ": " + error, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.red).padding(8)
        }
    }
}

struct SavedTerminalHistory: View {
    let active: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [TerminalHistory.Entry] = []
    @State private var selected: String?
    @State private var error: String?
    @State private var deleting: TerminalHistory.Entry?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text("Historial guardado")).font(.headline)
                Spacer()
                Button(L10n.text("Cerrar")) { dismiss() }
            }.padding()
            HSplitView {
                List(selection: $selected) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading) {
                            HStack {
                                SessionGroupMark(group: entry.group)
                                Text(entry.name)
                            }
                            if let group = entry.group { Text(group.name).font(.caption).foregroundStyle(.secondary) }
                            if let context = entry.context { Text(context).font(.caption).foregroundStyle(.secondary) }
                            Text(entry.created.formatted()).font(.caption).foregroundStyle(.secondary)
                        }.tag(entry.id)
                    }
                }.frame(minWidth: 200, idealWidth: 240)
                if let entry = entries.first(where: { $0.id == selected }) {
                    VStack {
                        RecordedTerminal(entry: entry).id(entry.id)
                        HStack {
                            Text(L10n.text("Grabación local · no ejecuta comandos")).font(.caption)
                            Spacer()
                            Button(L10n.text("Eliminar historial…"), role: .destructive) { deleting = entry }
                                .disabled(active.contains(entry.id))
                        }.padding()
                    }
                } else {
                    Text(L10n.text("Selecciona una sesión guardada")).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let error { Text(error).foregroundStyle(.red).padding() }
        }
        .frame(minWidth: 850, minHeight: 600)
        .onAppear { refresh() }
        .confirmationDialog(L10n.text("¿Eliminar este historial definitivamente?"), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button(L10n.text("Eliminar"), role: .destructive) {
                guard let deleting, !active.contains(deleting.id) else { return }
                do { try TerminalHistory.delete(deleting); self.deleting = nil; selected = nil; refresh() }
                catch { self.error = error.localizedDescription }
            }
        }
    }
    private func refresh() {
        do { entries = try TerminalHistory.entries(root: TerminalHistory.defaultDirectory) }
        catch { self.error = error.localizedDescription }
    }
}

private struct RecordedTerminal: View {
    let entry: TerminalHistory.Entry
    @StateObject private var feed = TerminalFeed()
    @State private var position = 1.0
    @State private var target = 1.0
    @State private var length: UInt64 = 0
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        VStack {
            TerminalCanvas(feed: feed, editable: false, input: { _ in }, resize: { _ in })
            HStack {
                Button { seek(max(0, target - step)) } label: { Image(systemName: "backward.end") }
                Slider(value: $position, in: 0...1) { editing in if !editing { target = position } }
                    .accessibilityLabel(L10n.text("Posición en el historial"))
                Button { seek(min(1, target + step)) } label: { Image(systemName: "forward.end") }
                Text(position, format: .percent.precision(.fractionLength(0))).monospacedDigit()
            }.padding(.horizontal)
            Text(L10n.text("Usa la barra para recorrer toda la grabación; desplázate en la terminal para ver las líneas cercanas."))
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            if loading { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .task(id: target) {
            loading = true; error = nil
            defer { loading = false }
            _ = feed.reset([], sequence: 0)
            do {
                let reader = try TerminalHistory.Reader(entry)
                length = reader.length
                let stop = UInt64(Double(length) * target)
                while reader.offset < stop {
                    try Task.checkCancellation()
                    for event in try reader.next(maxBytes: 8 * 1024) {
                        if let size = event.size { feed.resize(size) }
                        if let data = event.data { feed.append(data) }
                    }
                    // Yield between bounded batches so seeking a large recording remains cancellable.
                    try await Task.sleep(for: .milliseconds(1))
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    private var step: Double { length == 0 ? 1 : min(1, 8 * 1024 / Double(length)) }
    private func seek(_ value: Double) { position = value; target = value }
}
#endif
