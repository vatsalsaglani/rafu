import SwiftUI

/// The board's notice: one compact capsule under the tool palette, in the
/// same stack as the paused-links notice. It is never the save-failure
/// banner. A click on it, its close button, Escape on the board, the next
/// edit, or `CanvasBoardNotice.lifetime` dismisses it. VoiceOver reads it
/// once when it appears; the symbol and the words carry the tone, not the
/// colour alone.
struct CanvasBoardNoticeView: View {
    @Environment(\.rafuTheme) private var theme
    let board: CanvasBoardState

    var body: some View {
        if let notice = board.notice {
            capsule(notice)
                .transition(.opacity)
                .task(id: notice.id) {
                    AccessibilityNotification.Announcement(notice.message).post()
                    do { try await Task.sleep(for: CanvasBoardNotice.lifetime) } catch { return }
                    if board.notice?.id == notice.id { board.dismissNotice() }
                }
        }
    }

    private func capsule(_ notice: CanvasBoardNotice) -> some View {
        HStack(spacing: 6) {
            Image(systemName: notice.tone == .warn ? "exclamationmark.triangle" : "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(
                    notice.tone == .warn ? theme.palette.warning : theme.palette.textSecondary
                )
                .accessibilityHidden(true)
            Text(notice.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let action = notice.action {
                Text("·").foregroundStyle(theme.palette.textMuted).accessibilityHidden(true)
                // An agent edit's Undo is enabled only while no later edit
                // exists (`CanvasAgentUndoGate`); every other action is always on.
                let isEnabled = CanvasAgentProvenanceStore.shared.allowsAction(
                    noticeID: notice.id, board: board)
                Button(action.title) {
                    action.perform()
                    board.dismissNotice()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isEnabled ? theme.palette.textPrimary : theme.palette.textMuted)
                .disabled(!isEnabled)
            }
            Button {
                board.dismissNotice()
            } label: {
                Label("Dismiss", systemImage: "xmark")
            }
            .buttonStyle(RafuIconButtonStyle(size: 18, iconSize: 9))
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 4)
        .background(Capsule().fill(theme.palette.elevatedBackground))
        .overlay(Capsule().strokeBorder(theme.palette.borderSubtle))
        .frame(maxWidth: 560)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Capsule())
        .onTapGesture { board.dismissNotice() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(notice.tone == .warn ? "Ensemble warning" : "Ensemble notice")
    }
}
