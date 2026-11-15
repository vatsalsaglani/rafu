import SwiftUI

/// An agent's active sub-agents under its row, in the notch Agents tab, the
/// menu bar card, and Up next: a "3 sub-agents" chip that expands into one
/// line per sub-agent (type · model · short task description). A real
/// button, so it is keyboard reachable and VoiceOver speaks the count and
/// the types. Hidden when the agent has none. The expanded state is this
/// view's own; nothing is stored.
struct CompanionSubagentsView: View {
    let subagents: [NotchSubagentEntry]
    @State private var isExpanded = false
    @Environment(\.rafuTheme) private var theme

    private var ink: NotchInk { NotchInk(theme: theme) }

    var body: some View {
        if !subagents.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                chip
                if isExpanded {
                    ForEach(subagents) { subagent in
                        Text(subagent.line)
                            .font(.system(size: 10))
                            .foregroundStyle(ink.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(subagent.line)
                            .padding(.leading, RafuMetrics.space4)
                    }
                    if NotchSubagentEntry.needsReconnectNote(subagents) {
                        Text("Reconnect Activity tracking in Settings ▸ Agents to see names.")
                            .font(.system(size: 9))
                            .foregroundStyle(ink.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, RafuMetrics.space4)
                    }
                }
            }
            .padding(.leading, RafuMetrics.space4)
        }
    }

    private var chip: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .medium))
                Text(NotchSubagentEntry.chipText(count: subagents.count))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
            }
            .foregroundStyle(ink.secondary)
            .padding(.horizontal, RafuMetrics.space2 - 2)
            .frame(height: 18)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.06)))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide sub-agents" : "Show sub-agents")
        .accessibilityLabel(NotchSubagentEntry.spokenSummary(subagents))
        .accessibilityHint(isExpanded ? "Activates to hide the list" : "Activates to list them")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}
