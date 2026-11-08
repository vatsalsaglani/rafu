import RafuCore
import SwiftUI

/// The Agent control pill's words and glyph. Pure, so the grammar is
/// testable: a mode glyph plus the word, and "· N waiting" while actions wait.
nonisolated enum AgentControlPresentation {
    static func symbol(_ mode: CanvasAgentControlMode) -> String {
        switch mode {
        case .off: "hand.raised"
        case .ask: "questionmark.circle"
        case .allow: "checkmark.circle"
        }
    }

    /// "Allow", "Ask · 2 waiting".
    static func label(_ mode: CanvasAgentControlMode, waiting: Int) -> String {
        waiting > 0 ? "\(mode.title) · \(waiting) waiting" : mode.title
    }

    /// "Ask, 2 waiting for approval".
    static func accessibilityValue(_ mode: CanvasAgentControlMode, waiting: Int) -> String {
        waiting > 0 ? "\(mode.title), \(waiting) waiting for approval" : mode.title
    }
}

/// The Agent control chip in the Ensemble bar. It shows the setting and the
/// number of agent actions waiting for approval. Its popover is the approval
/// panel: it opens by itself when an agent asks, and it never blocks the board.
struct CanvasAgentControlItem: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let board: CanvasBoardState
    @State private var isPresented = false
    /// Bumped when the waiting count grows; one cross-fade per bump.
    @State private var arrivals = 0
    @State private var isDimmed = false
    private let center = CanvasAgentCenter.shared

    var body: some View {
        let pending = center.approvals(for: board.id).count
        let mode = board.agentControlMode
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: AgentControlPresentation.symbol(mode))
                    .accessibilityHidden(true)
                Text(AgentControlPresentation.label(mode, waiting: pending))
            }
            .font(.system(size: 11))
            .foregroundStyle(pending > 0 ? theme.palette.textPrimary : theme.palette.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(
                pending > 0
                    ? theme.palette.warning.opacity(0.18) : theme.palette.elevatedBackground,
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(theme.palette.borderSubtle, lineWidth: 1))
            .opacity(isDimmed ? 0.6 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Agent control for this Ensemble: what agents in its terminals may change.")
        .accessibilityLabel("Agent control")
        .accessibilityValue(AgentControlPresentation.accessibilityValue(mode, waiting: pending))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            CanvasAgentControlPanel(board: board)
        }
        .onChange(of: pending) { old, new in
            if new > old {
                isPresented = true
                arrivals += 1
            }
        }
        .task(id: arrivals) {
            // One cross-fade (0.6 → 1) when the waiting count grows; none
            // under Reduce Motion.
            guard arrivals > 0, !reduceMotion else { return }
            withAnimation(RafuMotion.stateCrossFade) { isDimmed = true }
            do { try await Task.sleep(for: .milliseconds(300)) } catch {
                isDimmed = false
                return
            }
            withAnimation(RafuMotion.stateCrossFade) { isDimmed = false }
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
            Divider()
            CanvasImagesFromTheWebRow(board: board)
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

/// "Images from the web: Allowed · Revoke" / "Not allowed", for this Ensemble.
/// Only the user can grant it (the consent card); this row can take it back.
private struct CanvasImagesFromTheWebRow: View {
    @Environment(\.rafuTheme) private var theme
    let board: CanvasBoardState

    var body: some View {
        let allowed = Self.isAllowed(board)
        HStack(spacing: 8) {
            Text("Images from the web")
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 8)
            Text(allowed ? "Allowed" : "Not allowed")
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.textSecondary)
            if allowed {
                Button("Revoke") {
                    if let provider = RemoteImageRevocation.shared.provider(for: board.id) {
                        provider.revokeConsent()
                    } else {
                        try? RemoteImageConsentWriter.revoke(on: board)
                    }
                }
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                .accessibilityHint("Stops images from the web in this Ensemble")
            }
        }
        .accessibilityElement(children: .contain)
        .help("Whether generated views in this Ensemble may load images from the web.")
    }

    /// Reading the stamp makes this row redraw after a grant, a revoke, or an undo.
    private static func isAllowed(_ board: CanvasBoardState) -> Bool {
        _ = board.changeStamp
        return board.remoteImageConsent?.allowed == true
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
