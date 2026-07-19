import RafuCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceWindowView: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            // Issue: flat sidebar. `NavigationSplitView` on macOS 26 floats
            // the sidebar as an inset, rounded Liquid Glass card whenever the
            // window is key — visible elevation, shadow, and margins that
            // contradict the flat chrome the user asked for (ADR 0012). An
            // AppKit-backed `HSplitView` keeps the sidebar an ordinary flush
            // pane while preserving drag-to-resize; ⌘B and the toolbar toggle
            // both drive `session.isSidebarCollapsed`.
            HSplitView {
                if !session.isSidebarCollapsed {
                    WorkspaceSidebarView(session: session)
                        .frame(minWidth: 200, idealWidth: 260, maxWidth: 420)
                        .frame(maxHeight: .infinity)
                }
                HStack(spacing: 0) {
                    // HSplitView is AppKit-backed and collapses to its
                    // children's ideal size unless every level is forced to
                    // fill; keep the explicit max frames and layout priority.
                    // Issue #4: the terminal presents as an editor tab inside
                    // `editorCanvas` now, not a separate docked panel here.
                    HSplitView {
                        editorCanvas
                            .frame(minWidth: 480, minHeight: 220)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)
                        if session.descriptor != nil, session.navigatorMode != .files {
                            WorkspaceUtilityPanelView(session: session)
                                .frame(minWidth: 250, idealWidth: 310, maxWidth: 460)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                    Divider().overlay(theme.palette.borderSubtle)
                    WorkspaceUtilityRail(session: session)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            WorkspaceStatusBar(session: session)
        }
        // `NavigationSplitView` used to contribute the system sidebar toggle;
        // with the flat `HSplitView` we provide the one toggle ourselves
        // (ADR 0002: exactly one sidebar toggle, plus the ⌘B keyboard path).
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    session.toggleSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("Toggle Sidebar (⌘B)")
                .accessibilityLabel("Toggle Sidebar")
            }
            // The window title, CENTERED. The system inline title renders at
            // the leading edge next to the traffic lights, which sits on top
            // of the sidebar and reads as a broken leftover header — so the
            // default title is removed below and re-added here as a quiet
            // principal item in the middle of the titlebar.
            ToolbarItem(placement: .principal) {
                Text(session.windowTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        // Hide the system's leading inline title; `navigationTitle` stays set
        // so Mission Control, the Window menu, and the proxy icon keep the
        // real title.
        .toolbar(removing: .title)
        .frame(minWidth: 720, minHeight: 480)
        .navigationTitle(session.windowTitle)
        .focusedSceneValue(\.workspaceSession, session)
        .fileImporter(
            isPresented: $session.isOpenFolderImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    return
                }
                session.openLocalWorkspace(at: url)
            case .failure(let error):
                session.reportOpenFolderError(error)
            }
        }
        .alert(session.openFolderErrorTitle, isPresented: $session.isOpenFolderErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.openFolderErrorMessage)
        }
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
        // Flat chrome (UI plan U1 / ADR 0012): drop the system toolbar band so
        // the themed panels meet the titlebar edge-to-edge behind the traffic
        // lights. Native toolbar items and window controls are retained.
        .toolbarBackground(.hidden, for: .windowToolbar)
    }

    private var editorCanvas: some View {
        EditorCanvasView(
            session: session,
            openFolder: session.requestOpenFolder
        )
    }

    private var cliMessageBinding: Binding<Bool> {
        Binding(
            get: { session.cliInstallMessage != nil },
            set: { if !$0 { session.cliInstallMessage = nil } }
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
