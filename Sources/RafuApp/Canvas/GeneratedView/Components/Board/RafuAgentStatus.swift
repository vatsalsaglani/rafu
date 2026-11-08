import JSONRenderClient
import JSONRenderCore
import JSONRenderSwiftUI
import SwiftUI

/// `AgentStatus`: who works in a terminal card and how it is doing. Read only.
@JRComponent(
    "AgentStatus",
    description: "The agent in a terminal card (id or title): its name and state.")
nonisolated struct RafuAgentStatus: View {
    @JRProp(description: "The terminal card's id or exact title.") var node: String
    @JRProp(description: "Optional agent name to show.") var agent: String?

    @Environment(\.generatedViewBoardContext) private var board
    @Environment(\.jsonRenderTheme) private var theme

    var body: some View {
        let card = board?.card(node)
        let status = card.flatMap { board?.agentStatus($0) }
        let name = agent ?? card.flatMap { board?.agentName($0) } ?? "Agent"
        HStack(spacing: theme.space.s2) {
            Image(systemName: "sparkles")
                .foregroundStyle(theme.color.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(theme.type.bodyEmphasis)
                    .foregroundStyle(theme.color.text)
                if let card {
                    Text(card.title)
                        .font(theme.type.caption)
                        .foregroundStyle(theme.color.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: theme.space.s2)
            if let status {
                AgentStatusPill(status: status)
            } else {
                Text(card == nil ? "Not found" : "No agent")
                    .font(theme.type.caption)
                    .foregroundStyle(theme.color.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(name))
        .accessibilityValue(Text(status?.word ?? (card == nil ? "Not found" : "No agent")))
    }
}
