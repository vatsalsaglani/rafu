import SwiftUI

/// Last-workspace restoration must happen exactly once per app launch: every
/// additional "New Workspace Window" starts empty instead of re-opening the
/// same folder.
@MainActor
private enum WorkspaceRestorationGate {
    static var hasRestored = false
}

struct WorkspaceSceneRoot: View {
    @State private var session = WorkspaceSession()
    @AppStorage("themeChoice") private var themeChoice = RafuThemeChoice.system.rawValue
    @AppStorage("themeRevision") private var themeRevision = 0
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        WorkspaceWindowView(session: session)
            .environment(\.rafuTheme, theme)
            .preferredColorScheme(preferredColorScheme)
            .background(
                WindowAccessor { window in
                    WorkspaceWindowRegistry.shared.register(
                        session: session, window: window, rootURL: { session.rootURL })
                }
            )
            .task {
                MemoryPressureMonitor.shared.register(session)
                // An externally requested folder (rafu CLI / Finder) wins
                // over last-workspace restoration for a fresh window.
                if let url = ExternalOpenRequests.shared.take() {
                    WorkspaceRestorationGate.hasRestored = true
                    session.openLocalWorkspace(at: url)
                    return
                }
                guard !WorkspaceRestorationGate.hasRestored else { return }
                WorkspaceRestorationGate.hasRestored = true
                await session.restoreLastWorkspaceIfAvailable()
            }
            .onChange(of: ExternalOpenRequests.shared.hasPending) { _, hasPending in
                // While running, the key window consumes CLI/Finder opens.
                guard hasPending, controlActiveState == .key else { return }
                if let url = ExternalOpenRequests.shared.take() {
                    session.openLocalWorkspace(at: url)
                }
            }
            .onDisappear {
                WorkspaceWindowRegistry.shared.deregister(session: session)
            }
    }

    private var choice: RafuThemeChoice? { RafuThemeChoice(rawValue: themeChoice) }
    private var theme: RafuTheme {
        _ = themeRevision
        return RafuThemeCatalog.resolved(identifier: themeChoice, systemScheme: systemScheme)
    }
    private var preferredColorScheme: ColorScheme? {
        choice == .system ? nil : theme.colorScheme
    }
}
