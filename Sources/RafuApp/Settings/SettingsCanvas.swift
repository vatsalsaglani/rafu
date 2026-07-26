import SwiftUI

/// Window-scoped editor host for the existing seven-pane Settings content.
/// The content itself remains reusable by the native Settings scene when no
/// workspace window exists.
struct SettingsCanvas: View {
    @Environment(\.rafuTheme) private var theme
    @Bindable var session: WorkspaceSession
    @State private var isHoveringCloseTab = false

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
            HStack(spacing: 7) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.info)
                    .accessibilityHidden(true)
                Text("Settings")
                    .lineLimit(1)
                    .foregroundStyle(theme.palette.textPrimary)
                Button("Close Settings", systemImage: "xmark", action: session.closeSettings)
                    .buttonStyle(RafuIconButtonStyle(size: 18, iconSize: 9))
                    .opacity(isHoveringCloseTab ? 1 : 0.75)
                    .accessibilityHint("Closes the Settings canvas")
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(height: RafuMetrics.tabBarHeight)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.palette.accent).frame(height: 2)
            }
            .overlay(alignment: .trailing) {
                Divider().frame(height: 18).overlay(theme.palette.borderSubtle)
            }
            .onHover { isHoveringCloseTab = $0 }
            Spacer()
        }
        .frame(height: RafuMetrics.tabBarHeight)
        .background(theme.palette.tabBarBackground)
    }
}
