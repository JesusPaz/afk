import SwiftUI
import AFKCore

// Hallmark · native workbench · design-system: design.md · P5 H4 E4 S5 R5 V4
// Native semantic colors retain system contrast and appearance behavior.
enum AFKStyle {
    static let accent = Color.accentColor
    static let connected = Color.green
    static let observing = Color.orange
    static let danger = Color.red
    static let terminalBackground = Color(red: 21 / 255, green: 23 / 255, blue: 25 / 255)
    static let terminalForeground = Color(red: 236 / 255, green: 239 / 255, blue: 241 / 255)
    static let terminalFontSize: CGFloat = 14
    #if os(macOS)
    static var terminalFont: NSFont {
        NSFont(name: "MesloLGSNFM-Regular", size: terminalFontSize)
            ?? .monospacedSystemFont(ofSize: terminalFontSize, weight: .regular)
    }
    #endif
}

struct ConnectionIndicator: View {
    let title: String
    let connected: Bool
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: connected ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(connected ? AFKStyle.connected : .secondary)
            Text(title)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

struct InstructionRow: View {
    let number: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.subheadline.monospaced().weight(.medium))
                .foregroundStyle(.secondary).frame(width: 24, height: 24)
                .background(.quaternary, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct InlineNotice: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.callout).foregroundStyle(AFKStyle.danger)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(L10n.format("Error: %@", text))
    }
}

struct TerminalCanvas: View {
    let feed: AFKCore.TerminalFeed
    let editable: Bool
    let input: (Data) -> Void
    let resize: (TerminalSize) -> Void
    var body: some View {
        TerminalSurface(feed: feed, editable: editable, input: input, resize: resize)
            .padding(8)
            .background(AFKStyle.terminalBackground)
    }
}
