import SwiftUI

/// Editor-hosted, workspace-wide Ensemble graph route. The interactive graph
/// body is layered onto this routing shell in the canvas implementation
/// stage; the shell itself keeps the peer-canvas and empty-state behavior
/// independently buildable.
struct ConductorGraphCanvas: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: WorkspaceNavigatorMode.runs.symbolName)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.info)
                    .accessibilityHidden(true)
                Text("Ensemble Graph")
                    .lineLimit(1)
                    .foregroundStyle(theme.palette.textPrimary)
                Button("Close Graph", systemImage: "xmark", action: session.closeConductorGraph)
                    .buttonStyle(RafuIconButtonStyle(size: 18, iconSize: 9))
                    .accessibilityHint("Closes the Ensemble graph")
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(height: RafuMetrics.tabBarHeight)
            .background(theme.palette.tabBarBackground)
            Divider().overlay(theme.palette.borderSubtle)
            ContentUnavailableView(
                "No Ensemble Runs",
                systemImage: WorkspaceNavigatorMode.runs.symbolName,
                description: Text("Runs appear here as a read-only graph once they are started.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.palette.editorBackground)
    }
}
