import SwiftUI

/// Typed renderer requests. TG-30 maps these requests to the frozen group
/// command contract; this view never gains workspace or process ownership.
nonisolated enum TerminalGroupViewAction: Equatable, Sendable {
    case focus(TerminalPaneID)
    case setDividerFraction(TerminalGroupSplitID, Double)
    case close(TerminalPaneID)
    case restart(TerminalPaneID)
    case start(TerminalPaneID)
}

/// The immutable textual presentation for a terminal pane. Keeping it pure
/// makes unavailable and stopped layouts safe to render with no controller.
nonisolated enum TerminalPanePresentation {
    static func name(for pane: TerminalPaneSnapshot) -> String {
        pane.explicitUserName?.rawValue
            ?? pane.reportedTitle?.rawValue
            ?? "Terminal Pane"
    }

    static func providerIdentity(for kind: TerminalPaneRuntimeKind) -> String {
        switch kind {
        case .ordinaryShell: "Shell"
        case .directAgentTerminal(let provider): provider.displayName
        case .ensembleRole: "Ensemble role"
        case .ensembleCoordinator: "Ensemble coordinator"
        case .unavailableAgentTerminal: "Agent Terminal"
        case .unavailableEnsemble: "Ensemble"
        }
    }

    static func statusLabel(
        for pane: TerminalPaneSnapshot,
        controllerStatus: TerminalSessionStatus?
    ) -> String {
        if controllerStatus == .bell { return "Attention" }
        return switch pane.status {
        case .idle: "Idle"
        case .live: "Running"
        case .exited: "Exited"
        case .stopped: "Stopped"
        case .unavailable: "Unavailable"
        }
    }

    static func unavailableMessage(for kind: TerminalPaneRuntimeKind) -> String? {
        switch kind {
        case .unavailableAgentTerminal:
            "Agent Terminal profiles are not saved in this version."
        case .unavailableEnsemble:
            "Ensemble terminal profiles are not saved in this version."
        case .ordinaryShell, .directAgentTerminal, .ensembleRole, .ensembleCoordinator:
            nil
        }
    }

    static func folderLabel(for pane: TerminalPaneSnapshot) -> String? {
        pane.launchProfile?.startingFolder.rawValue
    }
}

/// Snapshot-driven recursive Terminal Group renderer. It receives existing
/// controllers from its owner and only sends typed user intent back out.
struct TerminalGroupView: View {
    let snapshot: TerminalGroupSnapshot
    let controllerForPane: @MainActor (TerminalPaneID) -> WorkspaceTerminalController?
    let action: (TerminalGroupViewAction) -> Void
    let theme: RafuTheme
    var requestFocusToken: UInt64 = 0

    init(
        snapshot: TerminalGroupSnapshot,
        controllerForPane: @escaping @MainActor (TerminalPaneID) -> WorkspaceTerminalController?,
        action: @escaping (TerminalGroupViewAction) -> Void,
        theme: RafuTheme,
        requestFocusToken: UInt64 = 0
    ) {
        self.snapshot = snapshot
        self.controllerForPane = controllerForPane
        self.action = action
        self.theme = theme
        self.requestFocusToken = requestFocusToken
    }

    var body: some View {
        rendered(snapshot.root)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Terminal Group \(snapshot.name.rawValue)")
            .background(theme.palette.editorBackground)
    }

    private func rendered(_ node: TerminalGroupNode) -> AnyView {
        switch node {
        case .pane(let paneID):
            if let pane = snapshot.panes.first(where: { $0.id == paneID }) {
                AnyView(
                    TerminalGroupPaneView(
                        pane: pane,
                        controller: controllerForPane(paneID),
                        isFocused: snapshot.focusedPaneID == paneID,
                        requestFocusToken: requestFocusToken,
                        action: action,
                        theme: theme
                    )
                    .id(paneID)
                )
            } else {
                AnyView(
                    ContentUnavailableView("Terminal Pane Unavailable", systemImage: "terminal")
                        .id(paneID)
                )
            }
        case .split(let id, let axis, let fraction, let first, let second):
            AnyView(
                TerminalGroupSplitView(
                    id: id,
                    axis: axis,
                    fraction: fraction,
                    onUserDividerChange: { splitID, updatedFraction in
                        action(.setDividerFraction(splitID, updatedFraction))
                    },
                    first: { rendered(first) },
                    second: { rendered(second) }
                )
                .id(id)
                .accessibilityLabel(
                    axis == .columns ? "Terminal panes side by side" : "Terminal panes stacked")
            )
        }
    }
}

private struct TerminalGroupPaneView: View {
    let pane: TerminalPaneSnapshot
    let controller: WorkspaceTerminalController?
    let isFocused: Bool
    let requestFocusToken: UInt64
    let action: (TerminalGroupViewAction) -> Void
    let theme: RafuTheme

    var body: some View {
        VStack(spacing: 0) {
            header
            terminalContent
        }
        .background(theme.palette.editorBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(TerminalPanePresentation.name(for: pane)), \(statusLabel), \(folderAccessibilityLabel)"
        )
        .accessibilityValue(isFocused ? "Focused pane" : "Pane")
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(TerminalPanePresentation.name(for: pane))
                    .font(.callout.weight(.medium))
                Text(
                    "\(TerminalPanePresentation.providerIdentity(for: pane.runtimeKind)) · \(statusLabel)"
                )
                .font(.caption)
                .foregroundStyle(theme.palette.textSecondary)
                if let folderLabel = TerminalPanePresentation.folderLabel(for: pane) {
                    Text(folderLabel)
                        .font(.caption2)
                        .foregroundStyle(theme.palette.textSecondary)
                        .accessibilityLabel("Folder \(folderLabel)")
                }
                if isFocused {
                    Label("Focused pane", systemImage: "circle.inset.filled")
                        .font(.caption2.weight(.medium))
                        .accessibilityLabel("Focused pane")
                }
            }
            Spacer(minLength: 8)
            if pane.status == .exited, pane.runtimeKind == .ordinaryShell {
                Button("Restart", systemImage: "arrow.clockwise") {
                    action(.restart(pane.id))
                }
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                .accessibilityLabel("Restart \(TerminalPanePresentation.name(for: pane))")
            }
            if pane.status == .stopped, pane.startAvailability == .available {
                Button("Start Pane", systemImage: "play.fill") {
                    action(.start(pane.id))
                }
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            }
            Button("Close", systemImage: "xmark") {
                action(.close(pane.id))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(TerminalPanePresentation.name(for: pane))")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(theme.palette.cardBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.palette.borderSubtle)
                .frame(height: RafuMetrics.hairline)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var terminalContent: some View {
        if let controller {
            TerminalHostView(
                controller: controller,
                theme: theme,
                paneID: pane.id,
                isFocusedPane: isFocused,
                requestFocusToken: requestFocusToken,
                onDidBecomeFirstResponder: { paneID in
                    action(.focus(paneID))
                }
            )
        } else if let message = TerminalPanePresentation.unavailableMessage(for: pane.runtimeKind) {
            ContentUnavailableView(
                "Terminal Pane Unavailable", systemImage: "terminal", description: Text(message)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if pane.status == .stopped {
            ContentUnavailableView(
                "Terminal Pane Stopped",
                systemImage: "stop.circle",
                description: Text("Start this pane when you are ready.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Terminal Pane Unavailable",
                systemImage: "terminal",
                description: Text("The terminal controller is unavailable.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var statusLabel: String {
        TerminalPanePresentation.statusLabel(for: pane, controllerStatus: controller?.status)
    }

    private var folderAccessibilityLabel: String {
        if let folderLabel = TerminalPanePresentation.folderLabel(for: pane) {
            return "Folder \(folderLabel)"
        }
        return "No saved starting folder"
    }
}
