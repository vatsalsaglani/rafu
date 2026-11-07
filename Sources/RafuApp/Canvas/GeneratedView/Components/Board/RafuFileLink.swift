import JSONRenderClient
import JSONRenderCore
import JSONRenderSwiftUI
import RafuCore
import SwiftUI

/// `FileLink`: a workspace file chip. A press opens the file in Rafu. An
/// absolute path or one that leaves the workspace shows as text only.
@JRComponent(
    "FileLink",
    description: "A workspace file chip; press opens it in Rafu. path is workspace-relative.")
nonisolated struct RafuFileLink: View {
    @JRProp(description: "Workspace-relative path, for example Sources/App.swift.") var path: String
    @JRProp(description: "Optional line number.") var line: Int?
    @JRProp(description: "Optional text shown instead of the path.") var label: String?

    @Environment(\.generatedViewBoardContext) private var board

    var body: some View {
        RafuFileChip(path: path, line: line, label: label, board: board)
    }
}

/// The chip `FileLink` and `DiffSummary` share.
struct RafuFileChip: View {
    let path: String
    let line: Int?
    let label: String?
    let board: GeneratedViewBoardContext?
    @Environment(\.jsonRenderTheme) private var theme

    var body: some View {
        let relative = CanvasAgentPaths.normalizedRelative(path, allowRoot: false)
        let shown = label ?? (path + (line.map { ":\($0)" } ?? ""))
        if let relative, let board {
            Button {
                board.openFile(relative, line: line)
            } label: {
                RafuChipLabel(symbol: "doc.text", text: shown, theme: theme)
            }
            .buttonStyle(.plain)
            .help(relative)
            .accessibilityLabel(Text("Open \(shown)"))
            .accessibilityAddTraits(.isLink)
        } else {
            RafuChipLabel(symbol: "doc.text", text: shown, theme: theme)
                .accessibilityLabel(Text(shown))
        }
    }
}

/// A small rounded chip: symbol and text, keyboard-focusable when in a button.
struct RafuChipLabel: View {
    let symbol: String
    let text: String
    let theme: JSONRenderTheme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.color.textSecondary)
            Text(text)
                .font(theme.type.footnote.monospaced())
                .foregroundStyle(theme.color.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.control, style: .continuous)
                .fill(theme.color.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.control, style: .continuous)
                .strokeBorder(theme.color.hairline)
        )
        .contentShape(.rect)
    }
}
