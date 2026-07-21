import AppKit
import SwiftTerm
import SwiftUI

/// Terminal content for one `.terminal` editor tab (ADR 0004, issue #4): the
/// SwiftTerm view for `controller`'s shell, or a "shell exited" overlay with
/// a restart action when the shell has quit. The tab's own chrome (icon,
/// title, close button) lives in `EditorTerminalTabItem` — this view is only
/// ever mounted as the SELECTED tab's content, exactly like
/// `EditorDocumentView` for a file tab, inside `EditorGroupView`.
struct EditorTerminalTabContent: View {
    @Bindable var controller: WorkspaceTerminalController
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        ZStack {
            TerminalHostView(controller: controller, theme: theme)
                .id("\(controller.id)#\(controller.generation)")
            if !controller.isRunning {
                shellExitedOverlay
            }
        }
        .background(theme.palette.editorBackground)
    }

    private var shellExitedOverlay: some View {
        VStack(spacing: 10) {
            Text(exitedMessage)
                .font(.callout.weight(.medium))
                .foregroundStyle(theme.palette.textSecondary)
            Button("Restart Shell", systemImage: "arrow.clockwise") {
                controller.restart()
            }
            .buttonStyle(RafuSecondaryButtonStyle(compact: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.editorBackground.opacity(0.85))
    }

    /// "Shell exited" for a shutdown with no reported exit code (explicit
    /// close/restart) or a natural exit whose code SwiftTerm did not
    /// deliver; "Shell exited (N)" once a real exit code is known.
    private var exitedMessage: String {
        if case .exited(let code?) = controller.status {
            return "Shell exited (\(code))"
        }
        return "Shell exited"
    }
}

private struct TerminalHostView: NSViewRepresentable {
    let controller: WorkspaceTerminalController
    let theme: RafuTheme

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = controller.makeOrReuseView(theme: theme)
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        controller.applyTheme(theme, to: nsView)
    }
}
