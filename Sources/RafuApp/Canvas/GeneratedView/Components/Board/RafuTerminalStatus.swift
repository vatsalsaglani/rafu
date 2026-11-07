import JSONRenderClient
import JSONRenderCore
import JSONRenderSwiftUI
import SwiftUI

/// `TerminalStatus`: the live state of a terminal card. Read only.
@JRComponent(
    "TerminalStatus",
    description: "The live state of a terminal card (id or title): idle, running, needs you.")
nonisolated struct RafuTerminalStatus: View {
    @JRProp(description: "The terminal card's id or exact title.") var node: String
    @JRProp(description: "Optional text; default is the card's title.") var title: String?

    @Environment(\.generatedViewBoardContext) private var board
    @Environment(\.jsonRenderTheme) private var theme

    var body: some View {
        let card = board?.card(node)
        let pane = card.flatMap { board?.terminalPane($0) }
        let agent = card.flatMap { board?.agentStatus($0) }
        let word = agent?.word ?? pane.map { Self.word($0.status) } ?? "Not found"
        HStack(spacing: theme.space.s2) {
            Image(systemName: "terminal")
                .foregroundStyle(theme.color.textSecondary)
            Text(title ?? card?.title ?? node)
                .font(theme.type.bodyEmphasis)
                .foregroundStyle(theme.color.text)
                .lineLimit(1)
            Spacer(minLength: theme.space.s2)
            if let agent {
                AgentStatusPill(status: agent)
            } else {
                Text(word)
                    .font(theme.type.caption)
                    .foregroundStyle(theme.color.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Terminal \(title ?? card?.title ?? node)"))
        .accessibilityValue(Text(word))
    }

    static func word(_ status: TerminalPaneStatus) -> String {
        switch status {
        case .idle: "Idle"
        case .live: "Running"
        case .exited: "Exited"
        case .stopped: "Stopped"
        case .unavailable: "Unavailable"
        }
    }
}
