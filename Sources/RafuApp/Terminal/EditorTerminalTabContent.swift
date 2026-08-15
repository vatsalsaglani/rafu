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
            // Regression guard (terminal-manager.md T-E): `.bell` is NOT
            // `.running` (`controller.isRunning`), but it is very much NOT
            // exited either — testing `isRunning` here would wrongly show
            // "Shell exited" for a belling session. `isExited` is the
            // pure, separately-tested predicate for the actual exit state.
            if controller.showsShellExitedOverlay {
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

/// SwiftTerm's small SwiftUI hosting boundary. The default arguments preserve
/// the existing one-terminal editor-tab behaviour; Terminal Groups supply a
/// pane identity and opt in to the single focused-leaf responder bridge.
struct TerminalHostView: NSViewRepresentable {
    let controller: WorkspaceTerminalController
    let theme: RafuTheme
    var paneID: TerminalPaneID?
    var isFocusedPane = true
    var requestFocusToken: UInt64 = 0
    var onDidBecomeFirstResponder: ((TerminalPaneID) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = controller.makeOrReuseView(theme: theme)
        configureFocusCallback(on: view, coordinator: context.coordinator)
        requestFocusIfNeeded(on: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        controller.applyTheme(theme, to: nsView)
        configureFocusCallback(on: nsView, coordinator: context.coordinator)
        requestFocusIfNeeded(on: nsView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.invalidatePendingFocusRequest()
        (nsView as? RafuTerminalView)?.clearFirstResponderCallback(owner: coordinator)
        coordinator.paneID = nil
        coordinator.onDidBecomeFirstResponder = nil
    }

    private func configureFocusCallback(
        on view: LocalProcessTerminalView,
        coordinator: Coordinator
    ) {
        coordinator.onDidBecomeFirstResponder = onDidBecomeFirstResponder
        coordinator.paneID = paneID
        (view as? RafuTerminalView)?.setFirstResponderCallback(owner: coordinator) {
            [weak coordinator] in
            guard let paneID = coordinator?.paneID else { return }
            coordinator?.onDidBecomeFirstResponder?(paneID)
        }
    }

    private func requestFocusIfNeeded(on view: LocalProcessTerminalView, coordinator: Coordinator) {
        guard coordinator.allowsFocusRequest(isFocusedPane) else { return }
        guard coordinator.lastRequestedFocusToken != requestFocusToken else {
            return
        }
        coordinator.lastRequestedFocusToken = requestFocusToken
        coordinator.focusRequestGeneration &+= 1
        let token = requestFocusToken
        let generation = coordinator.focusRequestGeneration
        DispatchQueue.main.async { [weak coordinator, weak view] in
            guard
                let coordinator,
                token == coordinator.lastRequestedFocusToken,
                generation == coordinator.focusRequestGeneration,
                let view
            else { return }
            view.window?.makeFirstResponder(view)
        }
    }

    final class Coordinator {
        var paneID: TerminalPaneID?
        var onDidBecomeFirstResponder: ((TerminalPaneID) -> Void)?
        var lastRequestedFocusToken: UInt64?
        var focusRequestGeneration: UInt64 = 0

        func invalidatePendingFocusRequest() {
            focusRequestGeneration &+= 1
            lastRequestedFocusToken = nil
        }

        /// A view update can revoke focus after the request was queued but
        /// before the main queue executes it. Treat that as invalidation, not
        /// as a passive no-op.
        func allowsFocusRequest(_ isFocusedPane: Bool) -> Bool {
            guard isFocusedPane else {
                invalidatePendingFocusRequest()
                return false
            }
            return true
        }
    }
}
