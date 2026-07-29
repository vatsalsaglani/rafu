import SwiftUI

/// Window-scoped editor host for the existing seven-pane Settings content.
/// The content itself remains reusable by the native Settings scene when no
/// workspace window exists.
struct SettingsCanvas: View {
    @Environment(\.rafuTheme) private var theme
    @Bindable var session: WorkspaceSession

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider().overlay(theme.palette.borderSubtle)
            RafuSettingsView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.palette.editorBackground)
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            AttachedWorkbenchTab(isSelected: true) {
                HStack(spacing: RafuMetrics.space2) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.info)
                        .accessibilityHidden(true)
                    Text("Settings")
                        .lineLimit(1)
                    AttachedWorkbenchTabCloseButton(
                        accessibilityLabel: "Close Settings",
                        help: "Close Settings",
                        action: session.closeSettings
                    )
                    .accessibilityHint("Closes the Settings canvas")
                }
            }
            .font(.callout)
            .overlay(alignment: .trailing) {
                Divider().frame(height: 18).overlay(theme.palette.borderSubtle)
            }
            Spacer()
        }
        .frame(minHeight: RafuMetrics.tabBarHeight)
        .background(theme.palette.tabBarBackground)
    }
}
