import AppKit
import RafuCore
import SwiftUI

/// The window's titlebar row, 28 pt tall, Xcode and Safari style.
///
/// - Leading: room for the standard close / minimise / zoom buttons (drawn by
///   AppKit; no space is reserved in full screen) and the one sidebar toggle.
/// - Centre: the workspace name as a menu (saved workspaces, recent folders,
///   Open Folder, Open Workspace, Add Folder to Workspace, Save Workspace As,
///   Show All Workspaces, Reveal in Finder), the current branch, and, only
///   while agents run, an activity capsule that opens the Terminals panel.
/// - Trailing: a "Search" button that opens the palette in file mode.
/// - Everything else is a window-move surface. A double-click there performs
///   the action chosen in System Settings (zoom, minimise, or nothing).
struct WindowTitlebarRow: View {
    @Bindable var session: WorkspaceSession
    let isFullScreen: Bool

    @Environment(\.rafuTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow

    /// Explicit init: private stored properties would otherwise make the
    /// synthesized memberwise init private (Swift 6.3).
    init(session: WorkspaceSession, isFullScreen: Bool) {
        self.session = session
        self.isFullScreen = isFullScreen
    }

    /// Height of the standard titlebar, so the system buttons and the toggle
    /// share one centre line.
    nonisolated static let height: CGFloat = 28
    /// Width of the zone the system window buttons occupy (x ≈ 12…70).
    nonisolated static let trafficLightSpan: CGFloat = 76
    /// Width the trailing search button may use; the centre cluster keeps the
    /// same room on both sides so the title stays centred in the window.
    nonisolated static let sideReserve: CGFloat = 200
    nonisolated static let searchButtonWidth: CGFloat = 176

    private var workspaces: SavedWorkspacesModel { .shared }

    var body: some View {
        ZStack {
            TitlebarDragSurface()
            HStack(spacing: 0) {
                leading
                Spacer(minLength: 0)
                searchButton
                    .padding(.trailing, RafuMetrics.space2)
            }
            titleCluster
                .padding(.horizontal, Self.sideReserve)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        // The titlebar row sits on the window's frame, matching
        // `FlatWindowChrome`'s `NSWindow.backgroundColor` and the deck
        // lane's gutter — not the Files sidebar's own tone.
        .background(theme.palette.appBackground)
        .task(id: session.rootURL) { workspaces.reload() }
    }

    // MARK: - Leading

    private var leading: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: isFullScreen ? 8 : Self.trafficLightSpan, height: Self.height)
            Button("Toggle Sidebar", systemImage: "sidebar.left") {
                if let animation = RafuMotion.resolve(
                    RafuMotion.panelToggle, reduceMotion: reduceMotion)
                {
                    withAnimation(animation) { session.toggleSidebar() }
                } else {
                    session.toggleSidebar()
                }
            }
            .buttonStyle(RafuIconButtonStyle(size: 24, iconSize: 13))
            .help(session.isSidebarCollapsed ? "Show Sidebar (⌘B)" : "Hide Sidebar (⌘B)")
            .accessibilityLabel("Toggle Sidebar")
            .accessibilityValue(session.isSidebarCollapsed ? "Hidden" : "Shown")
        }
    }

    // MARK: - Centre

    private var workspaceName: String {
        session.descriptor?.displayName ?? RafuBuildInformation.appName
    }

    private var titleCluster: some View {
        HStack(spacing: RafuMetrics.space2) {
            workspaceMenu
            if let snapshot = session.gitBranchSnapshot {
                branchChip(StatusBarBranchFormatter.present(snapshot))
            } else if let summary = session.sourceControlBranchSummary {
                // Before Source Control loads branches, the status snapshot
                // from opening the workspace names the branch.
                branchChip(StatusBarBranchFormatter.present(summary: summary))
            }
            agentActivity
        }
        .lineLimit(1)
    }

    private var workspaceMenu: some View {
        Menu {
            if !otherSavedWorkspaces.isEmpty {
                Section("Saved Workspaces") {
                    ForEach(otherSavedWorkspaces) { entry in
                        Button(entry.displayName, systemImage: "square.stack.3d.up") {
                            open(entry)
                        }
                    }
                }
            }
            if !otherRecents.isEmpty {
                Section("Recent Folders") {
                    ForEach(otherRecents) { entry in
                        Button(entry.displayName, systemImage: "folder") { open(entry) }
                    }
                }
            }
            if !otherSavedWorkspaces.isEmpty || !otherRecents.isEmpty { Divider() }
            Button("Open Folder…", systemImage: "folder.badge.plus") {
                session.requestOpenFolder()
            }
            Button("Open Workspace…", systemImage: "square.stack.3d.up") {
                session.requestOpenWorkspaceFile()
            }
            Button("Add Folder to Workspace…", systemImage: "plus.rectangle.on.folder") {
                session.requestAddFolder()
            }
            .disabled(session.rootURL == nil)
            Button("Save Workspace As…", systemImage: "square.and.arrow.down") {
                session.requestSaveWorkspaceAs()
            }
            .disabled(session.rootURL == nil)
            Divider()
            Button("Show All Workspaces", systemImage: "rectangle.stack") {
                openWindow(id: WorkspacesWindow.id)
            }
            Button("Reveal in Finder", systemImage: "magnifyingglass") {
                if let url = session.rootURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            .disabled(session.rootURL == nil)
        } label: {
            HStack(spacing: 4) {
                Text(workspaceName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.palette.textMuted)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(theme.palette.textSecondary)
        .fixedSize()
        .help("Workspace: saved workspaces, recent folders, Add Folder, Save Workspace As")
        .accessibilityLabel("Workspace \(workspaceName)")
    }

    private var otherRecents: [RecentWorkspaceEntry] {
        Array(workspaces.recentFolders.filter { $0.rootPath != session.rootURL?.path }.prefix(5))
    }

    private var otherSavedWorkspaces: [SavedWorkspaceEntry] {
        let current = session.workspaceFileURL?.standardizedFileURL.path
        return Array(workspaces.savedWorkspaces.filter { $0.filePath != current }.prefix(5))
    }

    private func open(_ entry: RecentWorkspaceEntry) {
        guard let url = workspaces.resolve(entry) else {
            workspaces.remove(entry)
            return
        }
        session.openLocalWorkspace(at: url)
    }

    private func open(_ entry: SavedWorkspaceEntry) {
        Task {
            guard let url = await workspaces.resolve(entry) else {
                return workspaces.presentMissing(entry.displayName)
            }
            session.openWorkspaceFile(at: url)
        }
    }

    private func branchChip(_ branch: StatusBarBranchFormatter.Presentation) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .medium))
                .accessibilityHidden(true)
            Text(branch.label)
                .font(.system(size: 11, weight: .medium))
                .truncationMode(.middle)
        }
        .foregroundStyle(theme.palette.textSecondary)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Capsule().fill(theme.palette.chipBackground))
        .help(branch.isDetached ? "Detached HEAD at \(branch.label)" : "Branch \(branch.label)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            branch.isDetached ? "Detached HEAD at \(branch.label)" : "Branch \(branch.label)")
    }

    /// Shown only while at least one agent session runs. Live means gold, but
    /// the words carry the meaning, never the dot alone.
    @ViewBuilder
    private var agentActivity: some View {
        let summary = AgentActivitySummary(sessions: session.terminal.sessions)
        if summary.isActive {
            Button {
                session.showNavigator(.terminals)
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(theme.palette.accent)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    HStack(spacing: -3) {
                        ForEach(summary.providers.prefix(3), id: \.self) { cli in
                            AgentIconView(cli: cli, size: 12)
                        }
                    }
                    .accessibilityHidden(true)
                    Text(summary.label)
                        .font(.system(size: 11, weight: .medium))
                    if let attention = summary.attentionLabel {
                        Text("· \(attention)")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .foregroundStyle(theme.palette.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: 18)
                .background(Capsule().fill(theme.palette.chipBackground))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("\(summary.accessibilityLabel). Show Terminals.")
            .accessibilityLabel(summary.accessibilityLabel)
            .accessibilityHint("Shows the Terminals panel")
        }
    }

    // MARK: - Trailing

    private var searchButton: some View {
        Button {
            session.showCommandPalette(seed: "")
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityHidden(true)
                Text("Search \(workspaceName)")
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Text("⌘P")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.palette.textMuted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
        }
        .buttonStyle(TitlebarSearchButtonStyle())
        .frame(width: Self.searchButtonWidth, height: 20)
        .help("Search files and commands (⌘P)")
        .accessibilityLabel("Search \(workspaceName)")
        .accessibilityHint("Opens quick open")
    }
}

/// The titlebar's empty area: moves the window and, on a double-click, does
/// what the user chose in System Settings.
private struct TitlebarDragSurface: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    TitlebarDoubleClick.perform(in: NSApp.currentEvent?.window)
                }
            )
            .allowsWindowActivationEvents(true)
            .accessibilityHidden(true)
    }
}

/// Applies `TitlebarDoubleClickAction` to a window. The window comes from the
/// click event itself, so a second window never zooms the first.
@MainActor
enum TitlebarDoubleClick {
    static func perform(in window: NSWindow?) {
        guard let window, !window.styleMask.contains(.fullScreen), window.attachedSheet == nil
        else { return }
        switch TitlebarDoubleClickAction.current() {
        case .zoom: window.performZoom(nil)
        case .minimize: window.performMiniaturize(nil)
        case .none: break
        }
    }
}

/// Quiet capsule field look for the titlebar search button: hover wash,
/// pressed selection fill, and the theme focus ring for keyboard focus.
private struct TitlebarSearchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        @Environment(\.rafuTheme) private var theme
        @Environment(\.isFocused) private var isFocused
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(
                    isHovering ? theme.palette.textPrimary : theme.palette.textSecondary
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Capsule().fill(fill))
                .overlay(
                    Capsule().strokeBorder(
                        isFocused ? theme.palette.focusRing : theme.palette.borderSubtle,
                        lineWidth: isFocused ? 1.5 : RafuMetrics.hairline)
                )
                .contentShape(Capsule())
                .onHover { isHovering = $0 }
                .animation(isHovering ? RafuMotion.hoverIn : RafuMotion.hoverOut, value: isHovering)
        }

        private var fill: Color {
            if configuration.isPressed { return theme.palette.selection }
            return isHovering ? theme.palette.hover : theme.palette.chipBackground
        }
    }
}
