import RafuCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceWindowView: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.rafuTheme) private var theme

    /// The standard close / minimise / zoom buttons are always visible
    /// outside full screen; `WindowTitlebarRow` reserves their space.
    @State private var isWindowFullScreen = false
    /// Settings → Workspace → "Coloured file icons": read once per window
    /// and handed down, never per row.
    @AppStorage(FileIconProvider.colouredFileIconsKey) private var colouredFileIcons = false
    /// This window's voice companion: its corner, tuck and toggles.
    @State private var voiceCompanion = VoiceCompanionModel()

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
                    showsWelcome ? theme.palette.editorBackground : theme.palette.appBackground
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
        // Raised from 720, then from 760 when the HSplitView divider
        // became the explicit `WorkbenchSplitHandle`, then to 774 when the
        // deck inset grew to 10 pt: the left Activity Rail (40) + sidebar
        // min (220) + the handle's hit area (10) + deck lane (editor min
        // 472 + 20 pt inset) floor to 762; 774 keeps the same 12 pt margin
        // above it. See `workbenchContent`'s comment.
        .frame(minWidth: 774, minHeight: 480)
        .navigationTitle(session.windowTitle)
        .focusedSceneValue(\.workspaceSession, session)
        .focusedSceneValue(\.voiceCompanion, voiceCompanion)
        .onChange(of: session.terminal.terminalGroupRevision) { _, _ in
            session.canvas.refreshResourceSnapshots()
        }
        .onDisappear {
            // Window close and app termination share the session-owned,
            // idempotent lifecycle funnel; deinit remains a fallback.
            session.teardownTerminalGroups()
        }
        .modifier(WorkspaceWindowPresentations(session: session))
        // Outermost, so sheets and popovers inherit it too.
        .environment(\.rafuColouredFileIcons, colouredFileIcons)
        // Board cards report their drags, so the orb tucks away.
        .environment(voiceCompanion)
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
            // contradict the flat chrome the user asked for (ADR 0012).
            // `HSplitView` (AppKit-backed) avoided that, but reports no
            // divider callbacks and cannot collapse by drag — so the
            // boundary is now an explicit `WorkbenchSplitHandle` between two
            // ordinary HStack children, both driven by plain session state
            // (`sidebarWidth`, `isSidebarCollapsed`) instead of a second
            // AppKit split bridge. A second hosting view here would
            // re-derive the window's titlebar safe area on its own schedule
            // (flat-window-chrome-titlebar-merge.md rule 2), so this stays
            // pure SwiftUI. ⌘B, the titlebar toggle, and the handle's own
            // drag-to-collapse all drive `session.isSidebarCollapsed`.
            // One left Activity Rail (user decision 2026-10-19, superseding
            // ADR 0003's right-rail placement): it hosts every navigator
            // mode and is never gated on `isSidebarCollapsed` — only the
            // sidebar pane beside it is. There is no right rail and no right
            // utility panel.
            HStack(spacing: 0) {
                // The rail and sidebar sit above the deck: a later HStack
                // child is on top for hit testing, so deck content that
                // reaches past its edge (an Ensemble card) would otherwise
                // take the sidebar's clicks.
                WorkspaceActivityRail(session: session)
                    .zIndex(1)
                if !session.isSidebarCollapsed {
                    // A fixed `.frame(width:)` centres an over-wide child, which
                    // paints half of it over the Activity Rail. So sidebar
                    // content must declare no minimum above
                    // `WorkbenchSidebarResize.minimumWidth`; leading alignment
                    // plus the clip keep the rail on screen regardless.
                    WorkspaceSidebarPanelView(session: session)
                        .frame(
                            width: WorkbenchSidebarResize.clamp(session.sidebarWidth),
                            alignment: .leading
                        )
                        .clipped()
                        .frame(maxHeight: .infinity)
                        .zIndex(1)
                }
                // Present even while collapsed, right after the rail, so a
                // drag outward from the collapsed edge can reopen the
                // sidebar (see `WorkbenchSplitHandle`).
                WorkbenchSplitHandle(session: session)
                // Issue #4: the terminal presents as an editor tab inside
                // `editorCanvas` now, not a separate docked panel here.
                WorkbenchDeckSurface {
                    editorCanvas
                        // Resize floor: rail 40 + sidebar min 220 + the
                        // handle's 10 pt hit area + deck lane (this 472 +
                        // the 12 pt inset on both sides below, 24) = 766.
                        // The window's own `minWidth` (below, in `body`)
                        // is raised to 774 to clear it with a small margin.
                        // `sidebarWidth` is not window-responsive, so this
                        // floor holds only at a 220 pt sidebar. Below the
                        // true floor the deck clips at the trailing edge
                        // (the row aligns leading) instead of the rail
                        // vanishing off the leading edge.
                        .frame(minWidth: 472, minHeight: 220)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                }
                // Equal gutter on all four sides when the sidebar is
                // collapsed: the handle's hit area counts toward it.
                .padding(
                    WorkbenchDeckLane.padding(
                        isSidebarCollapsed: session.isSidebarCollapsed,
                        handleWidth: WorkbenchSplitHandle.hitAreaWidth
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.palette.appBackground)
                .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            // The voice companion: fixed in a corner of the workbench (it
            // does not pan or zoom with a board), above the editor and below
            // sheets, on every tab (voice-presence.md).
            .overlay(alignment: .topLeading) {
                VoiceCompanionHost(
                    model: voiceCompanion, session: VoiceSession.shared, workspace: session)
            }

            // The status bar owns its top boundary.
            WorkspaceStatusBar(session: session)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            .sheet(isPresented: $session.isOpenFolderErrorPresented) {
                RafuMessagePopup(
                    title: session.openFolderErrorTitle, message: session.openFolderErrorMessage
                ) {
                    session.isOpenFolderErrorPresented = false
                }
            }
            .sheet(isPresented: terminalGroupCloseBinding) {
                terminalGroupClosePopup
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
            .agentHandoffSheet(session: session)
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
            .sheet(isPresented: cliMessageBinding) {
                RafuMessagePopup(
                    kind: .info, title: "Command Line Tool",
                    message: session.cliInstallMessage ?? ""
                ) {
                    session.cliInstallMessage = nil
                }
            }
    }

    /// The confirmation for closing a terminal group or pane that still has
    /// a live process. Every button reaches a session method that clears
    /// `pendingTerminalGroupClose`; the sheet closes when the model does.
    private var terminalGroupClosePopup: some View {
        var actions: [RafuConfirmPopup.Action] = [
            .init(session.terminalGroupCloseConfirmationActionTitle, isDestructive: true) {
                session.confirmTerminalGroupClose()
            }
        ]
        if session.canSuppressPendingTerminalPaneCloseConfirmation {
            actions.append(
                .init("Close and Don’t Ask Again", isDestructive: true) {
                    session.confirmTerminalPaneCloseAndSuppressFutureWarnings()
                })
        }
        return RafuConfirmPopup(
            symbol: "terminal",
            title: session.terminalGroupCloseConfirmationTitle,
            message: session.terminalGroupCloseConfirmationMessage,
            actions: actions
        ) {
            session.cancelTerminalGroupClose()
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
        VStack(alignment: .leading, spacing: 0) {
            RafuPopupHeader(
                symbol: "questionmark.circle",
                title: "Quit Rafu?",
                subtitle: "No editor tabs are open in this window."
            )
            Toggle("Don’t ask again when the last editor is closed", isOn: $neverAskAgain)
                .padding(16)
            RafuPopupFooter(hints: [("↩", "Quit"), ("esc", "Cancel")]) {
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(RafuSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
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
        .frame(width: 430, alignment: .top)
        .rafuPopupSurface(.sheet)
        .onExitCommand { dismiss() }
    }
}
