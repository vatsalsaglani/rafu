import RafuCore
import SwiftUI

/// One Up next approval row. What the row shows is what runs: the command is
/// always shown whole (it is at most 2 KiB, and a command with blank space
/// that could push its end out of view is terminal-only), never cut to a few
/// lines while the answer buttons are active.
struct CompanionRequestView: View {
    let row: NotchAgentRow
    let request: CanvasAgentRequest
    let openTerminal: () -> Void
    let report: (String) -> Void
    /// False just after the rows changed (`ApprovalClickGuard`): a click then
    /// is ignored, so a double-click cannot answer the next request.
    var allowsClick: () -> Bool = { true }

    @State private var answers: [String: String] = [:]
    @Environment(\.rafuTheme) private var theme

    private var ink: NotchInk { NotchInk(theme: theme) }

    var body: some View {
        let presentation = CompanionRequestPresentation(
            request: request,
            decision: AgentRequestStore.shared.decision(for: row.id, key: request.key))
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            HStack(spacing: RafuMetrics.space2) {
                AgentIconView(cli: row.cli, size: 14)
                    .accessibilityHidden(true)
                Button(action: openTerminal) {
                    Text(row.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ink.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .help("Show this agent in its window")
                Spacer(minLength: 0)
            }
            Text(presentation.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.palette.warning)
            if let command = request.command {
                CompanionCommandBox(command: command, selectable: true)
                    .accessibilityLabel("\(row.cli.displayName) asks to run \(command)")
            }
            CompanionRequestDetails(request: request, showsReason: true)
            controls(presentation.controls)
        }
        .controlSize(.small)
        .padding(RafuMetrics.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func controls(_ controls: CompanionRequestPresentation.Controls) -> some View {
        switch controls {
        case .terminal:
            Button("Open terminal", action: openTerminal)
        case .sending:
            Text("Sending answer…")
                .font(.system(size: 11))
                .foregroundStyle(ink.secondary)
        case .options:
            CompanionRequestActionRow(
                actions: CompanionRequestActions(request: request),
                choose: choose,
                menuItems: [CompanionRequestMenuItem(title: "Open terminal", action: openTerminal)])
        case .questions(let questions):
            ForEach(questions, id: \.id) { question in
                if !question.header.isEmpty { Text(verbatim: question.header).bold() }
                Text(verbatim: question.text)
                ForEach(question.choices.indices, id: \.self) { index in
                    let choice = question.choices[index]
                    let selected = answers[question.id] == choice.label
                    Button {
                        answers[question.id] = choice.label
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text(verbatim: choice.label)
                                if !choice.detail.isEmpty {
                                    Text(verbatim: choice.detail).font(.caption)
                                }
                            }
                        } icon: {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        }
                    }
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            HStack(spacing: RafuMetrics.space2) {
                Button("Answer") { choose(.answers(answers)) }
                    .disabled(!request.permits(.answers(answers)))
                Button("Open terminal", action: openTerminal)
            }
        }
    }

    private func choose(_ decision: CanvasAgentRequestDecision) {
        guard allowsClick() else { return }
        let result = AgentRequestStore.shared.choose(
            controllerID: row.id, key: request.key, decision: decision)
        if let message = CompanionRequestPresentation.message(for: result) { report(message) }
    }
}

/// A command in a dark monospaced box. `lineLimit` nil shows it whole; only
/// a card with no accept answer (the peek's Review card) cuts it.
struct CompanionCommandBox: View {
    let command: String
    var lineLimit: Int?
    var selectable = false
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        let text = Text(verbatim: command)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(NotchInk(theme: theme).primary)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: lineLimit == nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, RafuMetrics.space2)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
        if selectable {
            text.textSelection(.enabled)
        } else {
            text
        }
    }
}

/// The muted lines under a request: the folder, the write root, the reason
/// (Up next only) and the permission lines.
struct CompanionRequestDetails: View {
    let request: CanvasAgentRequest
    var showsReason = false
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        let ink = NotchInk(theme: theme)
        VStack(alignment: .leading, spacing: 2) {
            if let cwd = request.cwd { Text(verbatim: "In \(cwd)") }
            if let root = request.grantRoot { Text(verbatim: "Write access to \(root)") }
            if showsReason, let reason = request.reason { Text(verbatim: reason) }
            ForEach(request.permissions.indices, id: \.self) { index in
                Text(verbatim: request.permissions[index])
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(ink.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One item of the "More actions" menu that is not an answer.
struct CompanionRequestMenuItem: Identifiable {
    let title: String
    let action: () -> Void
    var id: String { title }
}

/// The primary answer: an amber (theme warning) fill with dark text, so it
/// reads as the one prominent button of the row. Themed, never the system
/// accent.
struct CompanionAllowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        @Environment(\.rafuTheme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            configuration.label
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.black.opacity(isEnabled ? 0.88 : 0.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            theme.palette.warning.opacity(
                                configuration.isPressed ? 0.75 : (isEnabled ? 1 : 0.5)))
                )
                .overlay {
                    if contrast == .increased {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(theme.palette.borderStrong, lineWidth: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

/// One compact row of answer buttons: Deny, the primary answer (or Review),
/// and a "More actions" menu with the other answers and `menuItems`.
struct CompanionRequestActionRow: View {
    let actions: CompanionRequestActions
    /// Set on a card that cannot show the request whole: "Review" replaces
    /// the primary answer.
    var review: (() -> Void)?
    let choose: (CanvasAgentRequestDecision) -> Void
    var menuItems: [CompanionRequestMenuItem] = []

    var body: some View {
        HStack(spacing: RafuMetrics.space2) {
            if let deny = actions.deny {
                Button {
                    choose(deny.decision)
                } label: {
                    Text(deny.label).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            if let review {
                Button(action: review) {
                    Text("Review").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help("Show the full request")
            } else if let primary = actions.primary, let label = actions.primaryLabel {
                Button {
                    choose(primary.decision)
                } label: {
                    Text(label).frame(maxWidth: .infinity)
                }
                .buttonStyle(CompanionAllowButtonStyle())
            }
            if !actions.overflow.isEmpty || !menuItems.isEmpty {
                Menu {
                    ForEach(actions.overflow, id: \.id) { option in
                        Button(option.label) { choose(option.decision) }
                    }
                    if !actions.overflow.isEmpty && !menuItems.isEmpty { Divider() }
                    ForEach(menuItems) { item in
                        Button(item.title, action: item.action)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
                .accessibilityLabel("More actions")
            }
        }
    }
}
