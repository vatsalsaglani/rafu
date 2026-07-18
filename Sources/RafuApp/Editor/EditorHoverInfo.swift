import SwiftUI

/// The bounded hover payload the editor renders in its hover tooltip: the
/// server's flattened, length-capped signature/docstring, split into
/// `signature`/`documentation` by `HoverMarkdownParser`, plus the identifier
/// it describes (used only for the tooltip's accessibility label). Purely a
/// value type crossing the actor boundary from `WorkspaceSession.hoverInfo`
/// back to the `@MainActor` text view, so it honestly conforms to `Sendable`.
/// Every field here is a redaction-sensitive server payload — never log it.
nonisolated struct EditorHoverInfo: Sendable, Equatable {
    /// The flattened, multi-line, length-bounded hover text from the language
    /// server, unparsed. Never empty (an empty hover is a decline upstream).
    /// Kept as an accessibility/fallback source of truth alongside the
    /// structured `signature`/`documentation` split below.
    let text: String
    /// The identifier the hover describes, when one was resolvable under the
    /// pointer. Display/accessibility only — the LSP resolves hover by
    /// position, not by this name.
    let symbolName: String?
    /// The first fenced code block in `text`, fences and language tag
    /// stripped — the tooltip's clean, monospaced signature line(s). `nil`
    /// when the payload had no fenced code block.
    let signature: String?
    /// The prose outside the first fenced code block — the tooltip's
    /// lightly-rendered documentation. `nil` when there was nothing outside
    /// the fence (a signature-only hover).
    let documentation: String?
    /// Whether `documentation` should be interpreted as Markdown (inline
    /// emphasis/code spans/links) or shown as plain text.
    let isMarkdown: Bool
}

/// The SwiftUI content of the editor's hover tooltip popover: a compact,
/// theme-aware rendering of the server's hover — a clean monospaced
/// signature block over lightly-rendered Markdown documentation — plus a
/// de-emphasized "Go to Declaration" affordance. Hosted in an `NSPopover` by
/// `RafuTextView`; it owns no navigation logic itself, delegating the jump to
/// the caller so the tooltip stays a dumb, testable view.
///
/// `NSHostingController` does not inherit the SwiftUI environment, so the
/// theme is threaded in explicitly (`theme`) rather than read from
/// `\.rafuTheme`.
struct EditorHoverTooltipView: View {
    let info: EditorHoverInfo
    let theme: RafuTheme
    let onGoToDeclaration: () -> Void

    /// Fixed so the popover's measured height is deterministic: a variable
    /// width would make identical content report a different natural height
    /// across layout passes, defeating the measure-then-branch below.
    private static let contentWidth: CGFloat = 420
    /// Content taller than this scrolls instead of growing the popover
    /// further.
    private static let maxContentHeight: CGFloat = 360

    @State private var naturalHeight: CGFloat = 0
    /// Set once the first (unclamped) layout pass reports `naturalHeight`.
    /// Measurement then locks: once the view has switched into its scrolling
    /// branch, that branch's own (clamped) height must never feed back into
    /// `naturalHeight`, or the view would oscillate between the plain and
    /// scrolling layouts every frame.
    @State private var hasMeasuredNaturalHeight = false

    private var isScrolling: Bool { naturalHeight > Self.maxContentHeight }

    var body: some View {
        Group {
            if isScrolling {
                ScrollView {
                    content
                }
                .frame(height: Self.maxContentHeight)
            } else {
                content
            }
        }
        .frame(width: Self.contentWidth)
        .background(theme.palette.cardBackground)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
            guard !hasMeasuredNaturalHeight else { return }
            naturalHeight = newHeight
            hasMeasuredNaturalHeight = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let signature = info.signature {
                signatureBlock(signature)
            }
            if let documentation = info.documentation {
                documentationBlock(documentation)
            }
            if info.signature == nil, info.documentation == nil {
                // Defensive fallback: `text` is never empty, but if parsing
                // somehow yields neither part, show it plainly rather than
                // an empty box.
                Text(info.text)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(theme.palette.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(12)
    }

    /// The signature on a subtle theme "code surface" distinct from the
    /// popover's own background, selectable, wrapping within the fixed
    /// content width so a long single-line signature can never force the
    /// popover wide.
    @ViewBuilder
    private func signatureBlock(_ signature: String) -> some View {
        Text(signature)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(theme.palette.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusField, style: .continuous)
                    .fill(theme.palette.fieldBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusField, style: .continuous)
                    .strokeBorder(theme.palette.borderSubtle)
            )
    }

    /// Renders `documentation` as lightweight inline Markdown (bold, italic,
    /// inline code, links) when `info.isMarkdown` is set, falling back to
    /// plain text on a parse failure or when the payload isn't Markdown.
    /// Never crashes on malformed Markdown.
    @ViewBuilder
    private func documentationBlock(_ documentation: String) -> some View {
        if info.isMarkdown,
            let attributed = try? AttributedString(
                markdown: documentation,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        {
            Text(attributed)
                .font(.callout)
                .foregroundStyle(theme.palette.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(documentation)
                .font(.callout)
                .foregroundStyle(theme.palette.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// De-emphasized, borderless "Go to Declaration" affordance — a link,
    /// not a full-width primary button, so it doesn't dominate a short
    /// signature-only hover.
    private var footer: some View {
        Button("Go to Declaration", action: onGoToDeclaration)
            .buttonStyle(.link)
            .controlSize(.small)
            .tint(theme.palette.accent)
    }

    private var accessibilityLabel: String {
        if let symbolName = info.symbolName, !symbolName.isEmpty {
            return "\(symbolName). \(info.text)"
        }
        return info.text
    }
}
