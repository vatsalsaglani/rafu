import RafuCore
import SwiftUI

/// The Agent control chip in the Ensemble bar. It shows the setting and the
/// number of agent actions waiting for approval. Its popover is the approval
/// panel: it opens by itself when an agent asks, and it never blocks the board.
struct CanvasAgentControlItem: View {
    @Environment(\.rafuTheme) private var theme
    let board: CanvasBoardState
    @State private var isPresented = false
    private let center = CanvasAgentCenter.shared

    var body: some View {
        let pending = center.approvals(for: board.id).count
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.2.wave.2")
                    .accessibilityHidden(true)
                Text("Agents: \(board.agentControlMode.title)")
                if pending > 0 {
                    Text("\(pending)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.palette.textPrimary)
                        .padding(.horizontal, 5)
                        .background(theme.palette.accentSoft, in: Capsule())
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.palette.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(theme.palette.elevatedBackground, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.palette.borderSubtle, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Agent control for this Ensemble: what agents in its terminals may change.")
        .accessibilityLabel("Agent control")
        .accessibilityValue(
            pending > 0
                ? "\(board.agentControlMode.title), \(pending) waiting for approval"
                : board.agentControlMode.title
        )
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            CanvasAgentControlPanel(board: board)
        }
        .onChange(of: pending) { old, new in
            if new > old { isPresented = true }
        }
    }
}

private struct CanvasAgentControlPanel: View {
    @Environment(\.rafuTheme) private var theme
    let board: CanvasBoardState
    private let center = CanvasAgentCenter.shared

    var body: some View {
        let approvals = center.approvals(for: board.id)
        let log = center.log(for: board.id).suffix(8)
        VStack(alignment: .leading, spacing: 12) {
            CanvasAgentControlPicker(board: board)
            if !approvals.isEmpty {
                Divider()
                Text("Waiting for you").font(.headline)
                ForEach(approvals) { approval in
                    CanvasAgentApprovalRow(approval: approval)
                }
            }
            Divider()
            Text("Agent activity").font(.headline)
            if log.isEmpty {
                Text("No agent actions on this Ensemble yet.")
                    .font(.caption)
                    .foregroundStyle(theme.palette.textSecondary)
            } else {
                ForEach(Array(log.reversed())) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(entry.agent) · \(entry.action)")
                            .font(.system(size: 12, weight: .medium))
                        Text(entry.outcome)
                            .font(.caption)
                            .foregroundStyle(theme.palette.textSecondary)
                            .lineLimit(2)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .topLeading)
    }
}

private struct CanvasAgentControlPicker: View {
    @Environment(\.rafuTheme) private var theme
    let board: CanvasBoardState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agent control").font(.headline)
            RafuSegmentedPicker(
                items: CanvasAgentControlMode.allCases,
                selection: Binding(
                    get: { board.agentControlMode },
                    set: { mode in
                        board.setAgentControlMode(mode)
                        if mode != .allow { CanvasAgentCenter.shared.forgetGrants(on: board.id) }
                    }),
                fillsWidth: true
            ) { $0.title }
            Text(Self.explanation(board.agentControlMode))
                .font(.caption)
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func explanation(_ mode: CanvasAgentControlMode) -> String {
        switch mode {
        case .off:
            "Agents can read this Ensemble but cannot change it."
        case .ask:
            "Agents read freely. Rafu asks you before each change. Removing, starting processes, typing and opening apps always ask."
        case .allow:
            "Agents change this Ensemble without asking. Every change is logged here and can be undone."
        }
    }
}

private struct CanvasAgentApprovalRow: View {
    @Environment(\.rafuTheme) private var theme
    let approval: CanvasAgentApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(approval.agentName)
                .font(.system(size: 12, weight: .semibold))
            Text(approval.call.tool.actionTitle)
                .font(.system(size: 13))
            ForEach(Array(approval.summary.enumerated()), id: \.offset) { item in
                Text(item.element)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button("Allow Once") { CanvasAgentCenter.shared.decide(approval.id, .once) }
                    .buttonStyle(RafuProminentButtonStyle())
                if approval.allowsAlways {
                    Button("Always for This Ensemble") {
                        CanvasAgentCenter.shared.decide(approval.id, .always)
                    }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    .help(
                        "Allow this kind of change from agents on this Ensemble until Rafu quits.")
                }
                Button("Deny") { CanvasAgentCenter.shared.decide(approval.id, .deny) }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            }
        }
        .padding(10)
        .background(theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(approval.agentName) asks to \(approval.call.tool.actionTitle)")
    }
}
