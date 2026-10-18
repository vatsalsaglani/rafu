import SwiftUI

/// Settings no longer lives in an editor tab: ⌘, and every "Settings…" entry
/// point open the standard Settings window. This view remains only because
/// the editor-canvas routes (`EditorCanvasRoute.settings`,
/// `WorkspaceAuxiliaryTab.settings`) still name it; nothing in the UI or the
/// commands can reach them any more. If one is ever reached anyway, it opens
/// the Settings window and closes its own tab instead of hosting a second copy.
struct SettingsCanvas: View {
    @Environment(\.openSettings) private var openSettings
    @Bindable var session: WorkspaceSession
    var showsTabStrip = true

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "gearshape")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Settings opens in its own window.")
                .foregroundStyle(.secondary)
            Button("Open Settings") { openSettings() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            openSettings()
            session.closeSettings()
        }
    }
}
