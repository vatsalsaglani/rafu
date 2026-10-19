import SwiftUI

/// The compact link status in the Canvas bar (review 7.6, Global control):
/// "⇄ 1 live · 0 paused". It opens a popover with the Show Links choice, one
/// row per message link with a Pause or Resume toggle, plus Pause All Links
/// and Resume All. The menu bar's Ensemble menu keeps the same three actions.
/// The link part draws nothing when the board has no message links; the
/// Agent control chip beside it is always shown.
struct CanvasLinkStatusItem: View {
    @Environment(\.rafuTheme) private var theme
    let board: CanvasBoardState
    @State private var isPresented = false
    private let bridge = CanvasLiveBridge.shared

    var body: some View {
        HStack(spacing: 8) {
            // X4: the Agent control chip and approval panel sit beside the link status.
            CanvasAgentControlItem(board: board)
            linkStatus
        }
    }

    @ViewBuilder private var linkStatus: some View {
        let links = board.connections.filter { $0.isMessageLink }
        if !links.isEmpty {
            let states = bridge.linkStates(in: board)
            let summary = CanvasLinkSummary(states: links.compactMap { states[$0.id] })
            Button {
                isPresented.toggle()
            } label: {
                HStack(spacing: 0) {
                    Text(summary.liveText)
                        .foregroundStyle(
                            summary.live > 0 ? theme.palette.accent : theme.palette.textSecondary)
                    Text(" · " + summary.restText)
                        .foregroundStyle(theme.palette.textSecondary)
                }
                .font(.system(size: 11))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(theme.palette.elevatedBackground, in: Capsule())
                .overlay(Capsule().strokeBorder(theme.palette.borderSubtle, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Message links between terminals. Open to pause or resume each link.")
            .accessibilityLabel("Message links")
            .accessibilityValue(summary.text)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                CanvasLinkStatusPopover(board: board)
            }
        }
    }
}

private struct CanvasLinkStatusPopover: View {
    @Environment(\.rafuTheme) private var theme
    let board: CanvasBoardState
    private let bridge = CanvasLiveBridge.shared

    var body: some View {
        let links = board.connections.filter { $0.isMessageLink }
        let states = bridge.linkStates(in: board)
        let pausedCount = links.count { states[$0.id]?.kind == .paused }
        VStack(alignment: .leading, spacing: 10) {
            Text("Message links").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Show Links")
                    .font(.caption)
                    .foregroundStyle(theme.palette.textSecondary)
                    .accessibilityHidden(true)
                RafuSegmentedPicker(
                    items: CanvasLinkVisibility.allCases, selection: linkVisibility,
                    fillsWidth: true
                ) { $0.title }
                .help("Which links the board draws")
                .accessibilityLabel("Show Links")
            }
            if links.isEmpty {
                Text("No message links on this Ensemble.").foregroundStyle(.secondary)
            }
            ForEach(links) { link in
                row(link, state: states[link.id] ?? .paused)
            }
            Divider()
            HStack {
                Button("Pause All Links") { bridge.pauseAll(in: board) }
                    .disabled(links.isEmpty || pausedCount == links.count)
                Spacer()
                Button("Resume All") { bridge.resumeAll(in: board) }
                    .disabled(pausedCount == 0)
            }
            if let notice = bridge.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .controlSize(.small)
        .padding(12)
        .frame(width: 360, alignment: .leading)
    }

    private var linkVisibility: Binding<CanvasLinkVisibility> {
        Binding(get: { board.linkVisibility }, set: { board.linkVisibility = $0 })
    }

    private func title(of id: CanvasCardID) -> String {

        board.cards.first { $0.id == id }?.title ?? "Card"
    }

    private func row(_ link: CanvasConnection, state: CanvasLinkState) -> some View {
        let isPaused = state.kind == .paused
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title(of: link.from)) ⇄ \(title(of: link.to))")
                    .lineLimit(1)
                Text(state.badgeText)
                    .font(.caption)
                    .foregroundStyle(
                        state.kind == .live ? theme.palette.accent : theme.palette.textSecondary)
                if let reason = state.reason {
                    Text(reason).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button(isPaused ? "Resume" : "Pause") {
                if isPaused {
                    bridge.resume(link.id, in: board)
                } else {
                    bridge.pause(link.id, in: board)
                }
            }
            .accessibilityLabel(
                (isPaused ? "Resume link " : "Pause link ")
                    + "\(title(of: link.from)) to \(title(of: link.to))")
        }
        .accessibilityElement(children: .contain)
    }
}

struct CanvasTerminalSessionStatus: View {
    let groupID: TerminalGroupID
    let session: WorkspaceSession

    var body: some View {
        if let sessionID = session.terminal.terminalGroup(groupID)?.panes.first?.sessionID {
            Text(CanvasLiveBridge.shared.status(for: sessionID))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                .help(CanvasLiveBridge.shared.status(for: sessionID))
                .accessibilityLabel("Agent session status")
                .accessibilityValue(CanvasLiveBridge.shared.status(for: sessionID))
        } else {
            Text("Session bridge stopped").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
