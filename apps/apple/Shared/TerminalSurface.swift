import SwiftUI
import SwiftTerm
import AFKCore

#if os(macOS)
typealias PlatformView = NSView

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
        terminal = TerminalView(frame: .zero, font: AFKStyle.terminalFont)
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
    private var proposed: TerminalSize?
    private var pending: DispatchWorkItem?
    init(feed: TerminalFeed, editable: Bool, input: @escaping (Data) -> Void, resize: @escaping (TerminalSize) -> Void) {
        self.feed = feed; self.input = input; self.editable = editable; self.resize = resize
    }
    func attach(_ container: TerminalContainer) {
        let view = container.terminal
        view.terminalDelegate = self
        container.viewportChanged = { [weak self] size in
            guard let self, size != self.proposed else { return }
            self.proposed = size; self.pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.resize(size) }
            self.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }
        observation = feed.observe { [weak self, weak container] events, reset in
            guard let self, let container else { return }
            let view = container.terminal
            self.replaying = reset
            if reset {
                view.getTerminal().resetToInitialState()
                view.resize(cols: 80, rows: 24); container.fitRenderer()
            }
            for event in events {
                if let size = event.size {
                    view.resize(cols: size.columns, rows: size.rows); container.fitRenderer()
                }
                if let data = event.data { view.feed(byteArray: Array(data)[...]) }
            }
            self.replaying = false
        }
    }
    func detach() { pending?.cancel(); if let observation { feed.remove(observation) } }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { if editable && !replaying { input(Data(data)) } }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
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
    func makeCoordinator() -> TerminalCoordinator { TerminalCoordinator(feed: feed, editable: editable, input: input, resize: resize) }
    func makeNSView(context: Context) -> TerminalContainer {
        let view = TerminalContainer(frame: .zero)
        view.observing = !editable
        context.coordinator.attach(view)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view.terminal) }
        return view
    }
    func updateNSView(_ view: TerminalContainer, context: Context) {
        let gainedControl = editable && !context.coordinator.editable
        view.observing = !editable
        context.coordinator.editable = editable
        context.coordinator.input = input; context.coordinator.resize = resize
        if gainedControl { DispatchQueue.main.async { view.window?.makeFirstResponder(view.terminal) } }
    }
    static func dismantleNSView(_ view: TerminalContainer, coordinator: TerminalCoordinator) { coordinator.detach() }
}
#else
struct TerminalSurface: UIViewRepresentable {
    let feed: TerminalFeed
    let editable: Bool
    let input: (Data) -> Void
    let resize: (TerminalSize) -> Void
    func makeCoordinator() -> TerminalCoordinator { TerminalCoordinator(feed: feed, editable: editable, input: input, resize: resize) }
    func makeUIView(context: Context) -> TerminalContainer {
        let view = TerminalContainer(frame: .zero)
        context.coordinator.attach(view); return view
    }
    func updateUIView(_ view: TerminalContainer, context: Context) {
        context.coordinator.editable = editable; context.coordinator.input = input; context.coordinator.resize = resize
        if !editable && view.terminal.isFirstResponder { _ = view.terminal.resignFirstResponder() }
    }
    static func dismantleUIView(_ view: TerminalContainer, coordinator: TerminalCoordinator) { coordinator.detach() }
}
#endif
