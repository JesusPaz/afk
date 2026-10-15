import SwiftUI
import SwiftTerm
import AFKCore

@MainActor
final class TerminalCoordinator: NSObject, @preconcurrency TerminalViewDelegate {
    let feed: TerminalFeed
    var input: (Data) -> Void
    var editable: Bool
    var observation: UUID?
    init(feed: TerminalFeed, editable: Bool, input: @escaping (Data) -> Void) { self.feed = feed; self.input = input; self.editable = editable }
    func attach(_ view: TerminalView) {
        view.terminalDelegate = self
        view.resize(cols: 80, rows: 24)
        observation = feed.observe { [weak view] data, reset in
            guard let view else { return }
            if reset { view.getTerminal().resetToInitialState(); view.resize(cols: 80, rows: 24) }
            view.feed(byteArray: Array(data)[...])
        }
    }
    func detach() { if let observation { feed.remove(observation) } }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { if editable { input(Data(data)) } }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { if newCols != 80 || newRows != 24 { source.resize(cols: 80, rows: 24) } }
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
    func makeCoordinator() -> TerminalCoordinator { TerminalCoordinator(feed: feed, editable: editable, input: input) }
    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        context.coordinator.attach(view)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ view: TerminalView, context: Context) { context.coordinator.editable = editable; context.coordinator.input = input }
    static func dismantleNSView(_ view: TerminalView, coordinator: TerminalCoordinator) { coordinator.detach() }
}
#else
struct TerminalSurface: UIViewRepresentable {
    let feed: TerminalFeed
    let editable: Bool
    let input: (Data) -> Void
    func makeCoordinator() -> TerminalCoordinator { TerminalCoordinator(feed: feed, editable: editable, input: input) }
    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        context.coordinator.attach(view); return view
    }
    func updateUIView(_ view: TerminalView, context: Context) {
        context.coordinator.editable = editable; context.coordinator.input = input
        if !editable && view.isFirstResponder { view.resignFirstResponder() }
    }
    static func dismantleUIView(_ view: TerminalView, coordinator: TerminalCoordinator) { coordinator.detach() }
}
#endif
