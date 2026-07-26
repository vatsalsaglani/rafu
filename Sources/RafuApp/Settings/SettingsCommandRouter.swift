@MainActor
enum SettingsCommandRouter {
    /// Focused workspace windows own their Settings canvas. With no focused
    /// workspace — including when every window is closed — the registered
    /// native Settings scene is the reachable fallback.
    static func open(
        workspaceSession: WorkspaceSession?,
        openFallback: () -> Void
    ) {
        if let workspaceSession {
            workspaceSession.showSettings()
        } else {
            openFallback()
        }
    }
}
