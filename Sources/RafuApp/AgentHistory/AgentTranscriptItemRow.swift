import AppKit
import MarkdownUI
import RafuCore
import SwiftUI

/// One transcript entry. Prompts sit on a card, replies on the editor
/// background, tool calls and results are one collapsed line each, and
/// thinking is muted. Markdown goes through the shared MarkdownUI boundary
/// (`rafuMarkdownStyling`).
struct AgentTranscriptItemRow: View {
    enum MatchState {
        case none
        case match
        case current
    }

    let item: AgentTranscriptItem
    let provider: AgentHistoryProvider
    let isExpanded: Bool
    let matchState: MatchState
    let toggle: () -> Void
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Group {
            switch item.kind {
            case .message:
                AgentTranscriptMessageRow(item: item, provider: provider)
            case .command:
                AgentTranscriptCommandRow(item: item)
            case .toolCall, .toolResult:
                AgentTranscriptToolRow(item: item, isExpanded: isExpanded, toggle: toggle)
            case .thinking:
                AgentTranscriptThinkingRow(item: item)
            }
        }
        .overlay {
            if matchState != .none {
                RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseCard, style: .continuous)
                    .strokeBorder(
                        matchState == .current
                            ? theme.palette.focusRing : theme.palette.borderStrong,
                        lineWidth: matchState == .current ? 2 : 1
                    )
                    .padding(-4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Replies longer than this (in UTF-8 bytes) render as plain text:
/// MarkdownUI lays out a huge document slowly.
private let markdownByteLimit = 24_000

private struct AgentTranscriptMessageRow: View {
    let item: AgentTranscriptItem
    let provider: AgentHistoryProvider
    @Environment(\.rafuTheme) private var theme

    private var isUser: Bool { item.role == .user }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentTranscriptRoleHeader(item: item, provider: provider)
            AgentTranscriptMessageBody(text: item.text)
            if item.isTruncated {
                Text("This message is shortened.")
                    .font(.caption)
                    .foregroundStyle(theme.palette.textMuted)
            }
        }
        .padding(isUser ? RafuMetrics.space3 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isUser {
                RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseCard, style: .continuous)
                    .fill(theme.palette.cardBackground)
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: RafuMetrics.radiusDenseCard, style: .continuous
                        )
                        .strokeBorder(theme.palette.borderSubtle)
                    )
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct AgentTranscriptMessageBody: View {
    let text: String
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        if text.utf8.count > markdownByteLimit {
            Text(text)
                .font(.body.monospaced())
                .foregroundStyle(theme.palette.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Markdown(text)
                .rafuMarkdownStyling()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "You" or the agent, the time, and Copy.
private struct AgentTranscriptRoleHeader: View {
    let item: AgentTranscriptItem
    let provider: AgentHistoryProvider
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            if item.role == .user {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.palette.textSecondary)
                    .accessibilityHidden(true)
                Text("You")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.palette.textPrimary)
            } else {
                AgentIconView(cli: provider.cli, size: 13)
                Text(provider.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.palette.textPrimary)
            }
            if let timestamp = item.timestamp {
                Text(timestamp, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(theme.palette.textMuted)
            }
            Spacer(minLength: 4)
            AgentTranscriptCopyButton(text: item.text, label: "Copy Message")
        }
    }
}

private struct AgentTranscriptCopyButton: View {
    let text: String
    let label: String

    var body: some View {
        Button(label, systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        .buttonStyle(RafuIconButtonStyle(size: 22, iconSize: 10))
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct AgentTranscriptCommandRow: View {
    let item: AgentTranscriptItem
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.forward.square")
                .foregroundStyle(theme.palette.textSecondary)
                .accessibilityHidden(true)
            Text(item.text)
                .font(.callout.monospaced())
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            AgentTranscriptCopyButton(text: item.text, label: "Copy Command")
        }
        .padding(.horizontal, RafuMetrics.space2)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseCard, style: .continuous)
                .fill(theme.palette.chipBackground)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Command \(item.text)")
    }
}

/// One line, collapsed by default. Expanding shows the bounded arguments or
/// output in monospaced text.
private struct AgentTranscriptToolRow: View {
    let item: AgentTranscriptItem
    let isExpanded: Bool
    let toggle: () -> Void
    @Environment(\.rafuTheme) private var theme

    private var isCall: Bool { item.kind == .toolCall }
    private var name: String { item.toolName ?? (isCall ? "Tool" : "Result") }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                        .foregroundStyle(theme.palette.textMuted)
                    Image(systemName: symbol)
                        .font(.caption)
                        .foregroundStyle(
                            item.isError ? theme.palette.error : theme.palette.textSecondary)
                    Text(isCall ? name : "\(name) result")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.palette.textSecondary)
                    if item.isError {
                        Text("Error")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.palette.error)
                    }
                    Text(item.text)
                        .font(.caption.monospaced())
                        .foregroundStyle(theme.palette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(item.detail?.isEmpty ?? true)
            .accessibilityLabel(accessibilityText)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .help(isExpanded ? "Hide details" : "Show details")
            if isExpanded, let detail = item.detail, !detail.isEmpty {
                ScrollView(.horizontal) {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(theme.palette.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(RafuMetrics.space2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseCard, style: .continuous)
                        .fill(theme.palette.cardBackground)
                )
                .padding(.leading, 16)
            }
        }
    }

    private var symbol: String {
        if item.isError { return "exclamationmark.triangle" }
        return isCall ? "wrench.and.screwdriver" : "arrow.turn.down.left"
    }

    private var accessibilityText: String {
        let kind = isCall ? "Tool call \(name)" : "Tool result \(name)"
        return item.isError ? "\(kind), error, \(item.text)" : "\(kind), \(item.text)"
    }
}

private struct AgentTranscriptThinkingRow: View {
    let item: AgentTranscriptItem
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "brain")
                .font(.caption)
                .foregroundStyle(theme.palette.textMuted)
                .accessibilityHidden(true)
            Text(item.text)
                .font(.callout.italic())
                .foregroundStyle(theme.palette.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Thinking: \(item.text.prefix(300))")
    }
}
