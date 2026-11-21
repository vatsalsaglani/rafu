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
    /// Settings → Appearance → Window background and Frost.
    @AppStorage(WindowSurfacePreference.styleKey) private var windowSurfaceStyle =
        WindowSurfacePreference.Style.solid.rawValue
    @AppStorage(WindowSurfacePreference.frostLevelKey) private var windowSurfaceFrost =
        WindowSurfacePreference.FrostLevel.balanced.rawValue
    /// Settings → Appearance → "Frost the editor and terminals".
    @AppStorage(WindowSurfacePreference.frostContentKey) private var windowSurfaceFrostsContent =
        true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    /// The edge that holds the rail and sidebar, saved per user (not per
    /// workspace). `@AppStorage` makes every open window follow a change.
    @AppStorage(WorkbenchLayoutPreferences.sidebarEdgeKey) private var sidebarEdgeRaw =
        WorkbenchSidebarEdge.standard.rawValue
    /// This window's hold-⌘ badge timer and Escape tap.
    @State private var shortcutHints = NavigatorShortcutHintMonitor()

    private var sidebarEdge: WorkbenchSidebarEdge {
        WorkbenchSidebarEdge.resolve(raw: sidebarEdgeRaw)
    }

    /// Resolved per window. The welcome window is always Solid; Reduce
    /// Transparency and Increase Contrast force Solid live.
    private var windowSurface: WindowSurfacePreference.Resolved {
        guard !showsWelcome else { return .solid }
        return WindowSurfacePreference.resolve(
            style: windowSurfaceStyle,
            level: windowSurfaceFrost,
            frostsContent: windowSurfaceFrostsContent,
            isDark: theme.isDark,
            reduceTransparency: reduceTransparency,
            increaseContrast: colorSchemeContrast == .increased
        )
    }

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
        .background(
            NavigatorHintWindowReader { window in
                if let window {
                    installShortcutHints(in: window)
                } else {
                    shortcutHints.remove()
                }
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        )
        .onChange(of: session.isZenMode) { _, isOn in
            AccessibilityNotification.Announcement(
                WorkbenchLayoutShortcuts.zenAnnouncement(isOn: isOn)
            ).post()
        }
        .background(CanvasWindowCloseGuard(session: session).frame(width: 0, height: 0))
        .modifier(CanvasPresentations(session: session))
        // Raised from 720, then from 760 when the HSplitView divider
        // became the explicit `WorkbenchSplitHandle`, then to 774 when the
        // deck inset grew. Both window gap tightenings kept 774: the floor
        // is now the Activity Rail (38) + sidebar min (220) + deck lane
        // (editor min 472 + leading 8 + trailing 8) = 746 — the split
        // handle is an overlay and takes no width — so the deck gains 28 pt
        // at the minimum width. See `workbenchContent`'s comment.
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
        .environment(\.rafuWindowSurface, windowSurface)
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
            // One Activity Rail (user decision 2026-10-19, superseding
            // ADR 0003's right-rail placement): it hosts every navigator
            // mode and is never gated on `isSidebarCollapsed` — only the
            // sidebar pane beside it is. By default it sits on the leading
            // edge; the user may move the rail and sidebar to the trailing
            // edge (`WorkbenchSidebarEdge`), and Zen mode hides both in this
            // window. There is no second rail and no right utility panel.
            HStack(spacing: 0) {
                if sidebarEdge == .leading {
                    navigatorColumn
                }
                // Issue #4: the terminal presents as an editor tab inside
                // `editorCanvas` now, not a separate docked panel here.
                WorkbenchDeckSurface {
                    editorCanvas
                        // Resize floor: rail 38 + sidebar min 220 + deck
                        // lane (this 472 + the 8 pt leading and 8 pt
                        // trailing insets below) = 746; the split handle
                        // is an overlay and adds nothing. The window's own
                        // `minWidth` (above, in `body`) stays 774, clear of
                        // it.
                        // `sidebarWidth` is not window-responsive, so this
                        // floor holds only at a 220 pt sidebar. Below the
                        // true floor the deck clips at the trailing edge
                        // (the row aligns leading) instead of the rail
                        // vanishing off the leading edge.
                        .frame(minWidth: 472, minHeight: 220)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                }
                // Per-edge gutter (`RafuMetrics.deckInset*`); beside a
                // collapsed sidebar the rail's empty strip counts toward the
                // leading one.
                .padding(
                    WorkbenchDeckLane.padding(
                        // Zen mode has no rail, so no collapsed-rail strip.
                        isSidebarCollapsed: session.isSidebarCollapsed
                            && session.showsNavigatorRail,
                        railDeckSideInset: WorkspaceActivityRail.deckSideInset,
                        edge: sidebarEdge
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                if sidebarEdge == .trailing {
                    navigatorColumn
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            // One `.app` frame fill under the rail and the deck lane both, so
            // the deck's shadow shows under the rail's empty strip (the rail
            // has no fill of its own). The opaque sidebar still covers it.
            .rafuFrameSurface(.app)
            // Present even while collapsed, beside the rail, so a drag
            // outward from the collapsed edge can reopen the sidebar (see
            // `WorkbenchSplitHandle`). An overlay on the seam, above the
            // rail, sidebar, and deck for hit testing: it takes no layout
            // width, so only the gutter sets the gap.
            .overlay(alignment: sidebarEdge.seamOverlayAlignment) { sidebarSplitHandle }
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
        // Frosted: the one behind-window blur and the one frame tint, below
        // every frame surface (which then paints nothing). Not mounted in
        // Solid, so Solid costs nothing.
        .background {
            if windowSurface.isFrosted {
                WindowFrostBackdrop(
                    tint: theme.palette.appBackground, tintOpacity: windowSurface.tintOpacity)
            }
        }
    }

    /// The rail and sidebar pane, placed before or after the deck by
    /// `sidebarEdge`. In Zen mode it draws nothing.
    private var navigatorColumn: some View {
        WorkbenchNavigatorColumn(
            session: session, edge: sidebarEdge, showsShortcutHints: shortcutHints.isVisible)
    }

    /// The split handle, placed across the sidebar (or rail) to deck seam by
    /// `WorkbenchDeckLane.handleHitArea`. Zen mode has no seam, so no handle.
    @ViewBuilder
    private var sidebarSplitHandle: some View {
        if session.showsNavigatorRail {
            let isCollapsed = session.isSidebarCollapsed
            let hitArea = WorkbenchDeckLane.handleHitArea(
                isSidebarCollapsed: isCollapsed,
                railDeckSideInset: WorkspaceActivityRail.deckSideInset,
                edge: sidebarEdge
            )
            let paneEdge =
                WorkspaceActivityRail.width
                + (isCollapsed ? 0 : CGFloat(WorkbenchSidebarResize.clamp(session.sidebarWidth)))
            WorkbenchSplitHandle(session: session, hitAreaWidth: hitArea.width, edge: sidebarEdge)
                .offset(x: sidebarEdge.seamOffset(distance: paneEdge + hitArea.x))
        }
    }

    private func installShortcutHints(in window: NSWindow) {
        shortcutHints.escapeHandler = { [weak session = self.session] window in
            guard let session else { return false }
            return Self.leaveZenOnEscape(session: session, window: window)
        }
        shortcutHints.install(in: window)
    }

    /// Escape leaves Zen mode, but only when nothing else could want the key:
    /// not a text field, the editor, a terminal, a sheet, the tab switcher or
    /// an Ensemble board. See `ZenModeEscapePolicy`.
    private static func leaveZenOnEscape(session: WorkspaceSession, window: NSWindow) -> Bool {
        guard
            ZenModeEscapePolicy.shouldExit(
                isZenMode: session.isZenMode,
                responder: ZenModeEscapePolicy.classify(window.firstResponder),
                hasAttachedSheet: window.attachedSheet != nil,
                isEditorTabSwitcherOpen: session.editorTabSwitcherState != nil,
                isBoardSelected: session.selectedCanvas != nil)
        else { return false }
        session.exitZenMode()
        return true
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
