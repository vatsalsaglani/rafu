import SwiftUI

struct CanvasSessionLinksBar: View {
    let board: CanvasBoardState
    private let bridge = CanvasLiveBridge.shared

    private var sessionLinks: [CanvasConnection] {
        board.connections.filter { $0.behavior == .session }
    }
    private var enabledCount: Int { sessionLinks.count { bridge.isEnabled($0.id, in: board) } }

    var body: some View {
        if !sessionLinks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Label(
                        enabledCount == 0 ? "Session links paused" : "Session links active",
                        systemImage: enabledCount == 0 ? "pause.circle" : "link")
                    Text("Messages can pass both ways between connected agent sessions.")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Enable Links") {
                        for edge in sessionLinks { bridge.enable(edge.id, in: board) }
                    }
                    .disabled(enabledCount == sessionLinks.count)
                    Button("Pause Links") {
                        for edge in sessionLinks { bridge.disable(edge.id, in: board) }
                    }
                    .disabled(enabledCount == 0)
                }
                if let notice = bridge.notice {
                    Text(notice).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .font(.caption)
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .accessibilityElement(children: .contain)
        }
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
