import RafuCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceWindowView: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.rafuTheme) private var theme

    /// The standard close / minimise / zoom buttons are always visible
    /// outside full screen; `WindowTitlebarRow` reserves their space.
    @State private var isWindowFullScreen = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            windowContent
            if session.editorTabSwitcherState != nil {
                EditorTabSwitcherOverlay(session: session)
                    .zIndex(10)
            }
        }
        // Content merges with the titlebar zone because `FlatWindowChrome`
        // zeroes the top safe area at the window level
        // (`cancelTitlebarSafeArea`). Do NOT add `.ignoresSafeArea` escapes
        // here or on HSplitView panes — per-pane hosting views re-derive the
        // safe area on their own schedule, and view-level escapes drift
        // between under- and over-correction across window lifecycle events
        // (see flat-window-chrome-titlebar-merge.md).
        .background(
            FlatWindowChrome(
                titleBarColor: NSColor(
                    showsWelcome ? theme.palette.editorBackground : theme.palette.sidebarBackground
                ),
                topologyToken: windowChromeTopologyToken,
                hidesTrafficLights: false,
                onFullScreenChange: { isFullScreen in
                    isWindowFullScreen = isFullScreen
                }
            )
        )
        .background(
            EditorTabSwitcherEventBridge(
                isPresented: { session.editorTabSwitcherState != nil },
                move: session.moveEditorTabSwitcherSelection,
                commit: session.commitEditorTabSwitcher,
                cancel: session.cancelEditorTabSwitcher
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        )
        .background(CanvasWindowCloseGuard(session: session).frame(width: 0, height: 0))
        .modifier(CanvasPresentations(session: session))
        .frame(minWidth: 720, minHeight: 480)
        .navigationTitle(session.windowTitle)
        .focusedSceneValue(\.workspaceSession, session)
        .onChange(of: session.terminal.terminalGroupRevision) { _, _ in
            session.canvas.refreshResourceSnapshots()
        }
        .onDisappear {
            // Window close and app termination share the session-owned,
            // idempotent lifecycle funnel; deinit remains a fallback.
            session.teardownTerminalGroups()
        }
        .modifier(WorkspaceWindowPresentations(session: session))
    }

    private var showsWelcome: Bool {
        EditorCanvasRoute.resolve(EditorCanvasRoute.Inputs(session: session)) == .welcome
    }

    @ViewBuilder
    private var windowContent: some View {
        if showsWelcome {
            VStack(spacing: 0) {
                welcomeWindowHeader
                editorCanvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(theme.palette.editorBackground)
        } else {
            workbenchContent
        }
    }

    /// A new window has no navigator or utility actions yet. Keep a quiet
    /// drag surface and the native controls without an empty rail or toggle.
    private var welcomeWindowHeader: some View {
        HStack(spacing: 0) {
            WindowDragHandle()
                .frame(width: WindowTitlebarRow.trafficLightSpan)
            WindowDragHandle()
        }
        .frame(height: 42)
    }

    private var workbenchContent: some View {
        VStack(spacing: 0) {
            // Standard window buttons plus the one sidebar toggle.
            WindowTitlebarRow(session: session, isFullScreen: isWindowFullScreen)
            // Issue: flat sidebar. `NavigationSplitView` on macOS 26 floats
            // the sidebar as an inset, rounded Liquid Glass card whenever the
            // window is key — visible elevation, shadow, and margins that
            // contradict the flat chrome the user asked for (ADR 0012). An
            // AppKit-backed `HSplitView` keeps the sidebar an ordinary flush
            // pane while preserving drag-to-resize; ⌘B and the toolbar toggle
            // both drive `session.isSidebarCollapsed`.
            HStack(spacing: 0) {
                // Mirrors `WorkspaceUtilityRail` on the right edge. The
                // sidebar toggle lives in `WindowTitlebarRow` above.
                WorkspaceSidebarRail()
                Divider().overlay(theme.palette.borderSubtle)
                HSplitView {
                    if !session.isSidebarCollapsed {
                        WorkspaceSidebarView(session: session)
                            .frame(minWidth: 200, idealWidth: 260, maxWidth: 420)
                            .frame(maxHeight: .infinity)
                    }
                    HStack(spacing: 0) {
                        // HSplitView is AppKit-backed and collapses to its
                        // children's ideal size unless every level is forced
                        // to fill; keep the explicit max frames and layout
                        // priority. Issue #4: the terminal presents as an
                        // editor tab inside `editorCanvas` now, not a
                        // separate docked panel here.
                        WorkbenchDeckSurface {
                            HSplitView {
                                editorCanvas
                                    .frame(minWidth: 480, minHeight: 220)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .layoutPriority(1)
                                if session.descriptor != nil, session.navigatorMode != .files {
                                    WorkspaceUtilityPanelView(session: session)
                                        .frame(minWidth: 300, idealWidth: 340, maxWidth: 520)
                                        .frame(maxHeight: .infinity)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)
                        }
                        .padding(RafuMetrics.workbenchInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(theme.palette.appBackground)
                        .layoutPriority(1)
                        Divider().overlay(theme.palette.borderSubtle)
                        WorkspaceUtilityRail(session: session)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // The status bar owns its top boundary.
            WorkspaceStatusBar(session: session)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var editorCanvas: some View {
        EditorCanvasView(
            session: session,
            openFolder: session.requestOpenFolder
        )
    }

    /// A bounded identity snapshot for the one window-level AppKit bridge.
    /// Fractions, document text, terminal output, and other high-frequency
    /// state are deliberately absent: only hosting topology, selected canvas,
    /// and the logical navigation title can request a chrome reapply.
    private var windowChromeTopologyToken: FlatWindowChrome.TopologyToken {
        let layout = session.editorLayout
        return FlatWindowChrome.TopologyToken(
            editorNodes: Self.chromeEditorNodes(in: layout.root),
            focusedGroupID: layout.focusedGroupID.rawValue,
            canvasIdentity: windowChromeCanvasIdentity,
            windowTitleIdentity: session.windowTitle
        )
    }

    private var windowChromeCanvasIdentity: String {
        switch EditorCanvasRoute.resolve(EditorCanvasRoute.Inputs(session: session)) {
        case .welcome: "welcome"
        case .empty: "empty"
        case .blame: "blame:\(session.selectedDocumentID?.uuidString ?? "none")"
        case .standaloneDiff: "diff:\(session.gitOpenDiff?.id ?? "none")"
        case .settings: "settings"
        case .editor: "editor:\(session.selectedDocumentID?.uuidString ?? "none")"
        }
    }

    private static func chromeEditorNodes(
        in node: EditorLayoutNode
    ) -> [FlatWindowChrome.TopologyToken.EditorNode] {
        switch node {
        case .group(let group):
            return [
                .group(
                    id: group.id.rawValue,
                    tabIDs: group.tabs.map(\.id.rawValue),
                    selectedTabID: group.selectedTabID?.rawValue
                )
            ]
        case .split(let id, let axis, _, let first, let second):
            return [.split(id: id.rawValue, axis: axis.rawValue)]
                + chromeEditorNodes(in: first)
                + chromeEditorNodes(in: second)
        }
    }
}

/// The window's importer, alert, and sheet presentations, split out so
/// `WorkspaceWindowView.body` stays the layout story (content + top-left
/// cluster + chrome).
private struct WorkspaceWindowPresentations: ViewModifier {
    @Bindable var session: WorkspaceSession

    private var terminalGroupCloseBinding: Binding<Bool> {
        Binding(
            get: { session.pendingTerminalGroupClose != nil },
            // SwiftUI writes false after a destructive dialog action. The
            // model may intentionally enqueue a fresh stale-close request on
            // the next MainActor turn, so only the explicit Cancel button
            // owns cancellation.
            set: { _ in }
        )
    }

    func body(content: Content) -> some View {
        content
            .alert(session.openFolderErrorTitle, isPresented: $session.isOpenFolderErrorPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(session.openFolderErrorMessage)
            }
            .confirmationDialog(
                session.terminalGroupCloseConfirmationTitle,
                isPresented: terminalGroupCloseBinding,
                titleVisibility: .visible
            ) {
                Button(session.terminalGroupCloseConfirmationActionTitle, role: .destructive) {
                    session.confirmTerminalGroupClose()
                }
                if session.canSuppressPendingTerminalPaneCloseConfirmation {
                    Button("Close and Don’t Ask Again", role: .destructive) {
                        session.confirmTerminalPaneCloseAndSuppressFutureWarnings()
                    }
                }
                Button("Cancel", role: .cancel) { session.cancelTerminalGroupClose() }
            } message: {
                Text(session.terminalGroupCloseConfirmationMessage)
            }
            .sheet(item: terminalGroupSaveRequestBinding) { request in
                TerminalGroupSaveSheet(session: session, request: request)
            }
            .sheet(item: terminalGroupRenameRequestBinding) { request in
                TerminalGroupRenameSheet(session: session, request: request)
            }
            .fileImporter(
                isPresented: terminalPaneStartingFolderBinding,
                allowedContentTypes: [.folder], allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        let accessed = url.startAccessingSecurityScopedResource()
                        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                        session.completePendingTerminalPaneStartingFolder(url)
                    } else {
                        session.cancelPendingTerminalPaneStartingFolder()
                    }
                case .failure:
                    session.cancelPendingTerminalPaneStartingFolder()
                }
            }
            .fileDialogDefaultDirectory(
                session.pendingTerminalPaneStartingFolderRequest?.initialDirectory
            )
            .sheet(isPresented: $session.isCommandPalettePresented) {
                CommandPaletteView(session: session)
            }
            .sheet(isPresented: $session.isNavigationPeekPresented) {
                NavigationPeekView(session: session)
            }
            .sheet(isPresented: $session.isQuitConfirmationPresented) {
                EmptyWindowQuitConfirmationView()
            }
            .sheet(isPresented: $session.isGitHubPublishPresented) {
                GitHubPublishSheet(session: session)
            }
            .sheet(isPresented: $session.agentTerminalSheetPresented) {
                AgentTerminalSheet(session: session)
            }
            .sheet(isPresented: ignoreSuggestionPresentedBinding) {
                IgnoreSuggestionSheet(session: session)
            }
            .sheet(item: trustPromptBinding) { request in
                LanguageServerTrustPromptView(
                    request: request,
                    onApprove: { session.languageIntelligence.approveTrust($0) },
                    onDecline: { session.languageIntelligence.declineTrust($0) }
                )
            }
            .alert("Command Line Tool", isPresented: cliMessageBinding) {
                Button("OK", role: .cancel) { session.cliInstallMessage = nil }
            } message: {
                Text(session.cliInstallMessage ?? "")
            }
    }

    private var cliMessageBinding: Binding<Bool> {
        Binding(
            get: { session.cliInstallMessage != nil },
            set: { if !$0 { session.cliInstallMessage = nil } }
        )
    }

    private var terminalGroupSaveRequestBinding: Binding<WorkspaceSession.TerminalGroupSaveRequest?>
    {
        Binding(
            get: { session.pendingTerminalGroupSaveRequest },
            set: { request in
                if request == nil, !session.isPendingTerminalGroupSaveSubmission {
                    session.cancelPendingTerminalGroupSave()
                }
            }
        )
    }

    private var terminalGroupRenameRequestBinding:
        Binding<WorkspaceSession.TerminalGroupRenameRequest?>
    {
        Binding(
            get: { session.pendingTerminalGroupRenameRequest },
            set: { if $0 == nil { session.cancelPendingTerminalGroupRename() } }
        )
    }

    private var terminalPaneStartingFolderBinding: Binding<Bool> {
        Binding(
            get: { session.pendingTerminalPaneStartingFolderRequest != nil },
            set: { if !$0 { session.cancelPendingTerminalPaneStartingFolder() } }
        )
    }

    /// Presents `IgnoreSuggestionSheet`. An interactive dismissal (Escape,
    /// click-outside) routes through the setter to `cancelIgnoreSuggestion()`
    /// so a dismissed suggestion never leaves its background task running,
    /// mirroring `trustPromptBinding`.
    private var ignoreSuggestionPresentedBinding: Binding<Bool> {
        Binding(
            get: { session.isIgnoreSuggestionPresented },
            set: { newValue in
                guard !newValue else { return }
                session.cancelIgnoreSuggestion()
            }
        )
    }

    /// Presents `session.languageIntelligence.pendingTrustRequest` as a
    /// sheet. `pendingTrustRequest` is read-only from outside the
    /// coordinator, so an interactive dismissal (Escape, click-outside)
    /// routes through the setter to `declineTrust(_:)` — guarded so it only
    /// fires when a request is still pending, keeping an explicit
    /// `approveTrust`/`declineTrust` call (which already cleared it) from
    /// triggering a redundant, no-op decline.
    private var trustPromptBinding: Binding<TrustRequest?> {
        Binding(
            get: { session.languageIntelligence.pendingTrustRequest },
            set: { newValue in
                guard newValue == nil,
                    let pending = session.languageIntelligence.pendingTrustRequest
                else { return }
                session.languageIntelligence.declineTrust(pending)
            }
        )
    }
}

private struct EmptyWindowQuitConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var neverAskAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RafuSheetHeader(
                icon: "questionmark.circle",
                title: "Quit Rafu?",
                subtitle: "No editor tabs are open in this window."
            )
            Toggle("Don’t ask again when the last editor is closed", isOn: $neverAskAgain)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(RafuSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Quit") {
                    if neverAskAgain {
                        UserDefaults.standard.set(
                            true,
                            forKey: "quitWithoutEmptyWindowConfirmation"
                        )
                    }
                    NSApp.terminate(nil)
                }
                .buttonStyle(RafuProminentButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(RafuMetrics.sheetPadding)
        .frame(width: 430)
    }
}
