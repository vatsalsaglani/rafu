import SwiftUI

/// The bounded hover payload the editor renders in its hover tooltip: the
/// server's flattened, length-capped signature/docstring plus the identifier
/// it describes (used only for the tooltip's accessibility label). Purely a
/// value type crossing the actor boundary from `WorkspaceSession.hoverInfo`
/// back to the `@MainActor` text view, so it honestly conforms to `Sendable`.
/// The `text` is a redaction-sensitive server payload — never log it.
nonisolated struct EditorHoverInfo: Sendable, Equatable {
    /// The flattened, multi-line, length-bounded hover text from the language
    /// server. Never empty (an empty hover is a decline upstream).
    let text: String
    /// The identifier the hover describes, when one was resolvable under the
    /// pointer. Display/accessibility only — the LSP resolves hover by
    /// position, not by this name.
    let symbolName: String?
}

/// The SwiftUI content of the editor's hover tooltip popover: a monospaced,
/// bounded-height, scroll-when-long rendering of the server's hover text plus
/// a "Go to Declaration" affordance. Hosted in an `NSPopover` by
/// `RafuTextView`; it owns no navigation logic itself, delegating the jump to
/// the caller so the tooltip stays a dumb, testable view.
struct EditorHoverTooltipView: View {
    let info: EditorHoverInfo
    let onGoToDeclaration: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(info.text)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 220)

            Divider()

            Button("Go to Declaration", action: onGoToDeclaration)
                .controlSize(.small)
        }
        .padding(12)
        .frame(minWidth: 240, idealWidth: 340, maxWidth: 460)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if let symbolName = info.symbolName, !symbolName.isEmpty {
            return "\(symbolName). \(info.text)"
        }
        return info.text
    }
}
