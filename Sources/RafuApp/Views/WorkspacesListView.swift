import AppKit
import RafuCore
import SwiftUI

/// Saved workspaces and recent folders, with a search field. Shown in the
/// "Workspaces" window and on the welcome screen.
///
/// Return or a double-click opens the selected row; the context menu and the
/// row's "More" button offer Open, Reveal in Finder, and Remove from List.
/// Removing only forgets the entry; files and folders are never deleted.
struct WorkspacesListView: View {
    enum Placement: Equatable {
        /// The Workspaces window: opens in an existing or new window.
        case window
        /// A workspace window's welcome screen: opens in that window.
        case welcome
    }

    let model: SavedWorkspacesModel
    let session: WorkspaceSession?
    let placement: Placement

    @Environment(\.rafuTheme) private var theme
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var isSearchFocused: Bool

    init(model: SavedWorkspacesModel, session: WorkspaceSession?, placement: Placement) {
        self.model = model
        self.session = session
        self.placement = placement
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            searchField
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { model.reload() }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.palette.textMuted)
                .accessibilityHidden(true)
            TextField("Search workspaces", text: $query)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .accessibilityLabel("Search workspaces")
                .onSubmit { openSelectionOrFirst() }
        }
        .rafuField(isFocused: isSearchFocused)
    }

    private var savedRows: [SavedWorkspaceEntry] {
        SavedWorkspaceList.filter(model.savedWorkspaces, query: query)
    }

    private var recentRows: [RecentWorkspaceEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return model.recentFolders }
        return model.recentFolders.filter {
            SavedWorkspaceList.matches($0.displayName, needle)
                || SavedWorkspaceList.matches($0.rootPath, needle)
        }
    }

    @ViewBuilder
    private var list: some View {
        let saved = savedRows
        let recent = recentRows
        if saved.isEmpty && recent.isEmpty {
            emptyState
        } else {
            List(selection: $selection) {
                if !saved.isEmpty {
                    Section("Saved Workspaces") {
                        ForEach(saved) { entry in
                            WorkspacesListRow(
                                presentation: .saved(entry),
                                onOpen: { open(entry) },
                                onReveal: { model.revealInFinder(entry) },
                                onRemove: { model.remove(entry) }
                            )
                            .tag(Self.tag(entry))
                        }
                    }
                }
                if !recent.isEmpty {
                    Section("Recent Folders") {
                        ForEach(recent) { entry in
                            WorkspacesListRow(
                                presentation: .recent(entry),
                                onOpen: { open(entry) },
                                onReveal: { model.revealInFinder(entry) },
                                onRemove: { model.remove(entry) }
                            )
                            .tag(Self.tag(entry))
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: String.self) { tags in
                if let tag = tags.first, tags.count == 1 {
                    Button("Open") { open(tag: tag) }
                    Button("Reveal in Finder") { reveal(tag: tag) }
                    Divider()
                    Button("Remove from List") { remove(tag: tag) }
                }
            } primaryAction: { tags in
                if let tag = tags.first { open(tag: tag) }
            }
            .accessibilityLabel("Workspaces")
        }
    }

    private var emptyState: some View {
        VStack(spacing: RafuMetrics.space2) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
                .accessibilityHidden(true)
            Text(query.isEmpty ? "No Workspaces Yet" : "No Matching Workspaces")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
            Text(
                query.isEmpty
                    ? "Open a folder, or use File > Save Workspace As… to save one."
                    : "Try another name or folder path."
            )
            .font(.system(size: 12))
            .foregroundStyle(theme.palette.textSecondary)
            .multilineTextAlignment(.center)
        }
        .padding(RafuMetrics.space4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private static func tag(_ entry: SavedWorkspaceEntry) -> String { "saved:" + entry.filePath }
    private static func tag(_ entry: RecentWorkspaceEntry) -> String { "recent:" + entry.rootPath }

    private func open(tag: String) {
        if let entry = model.savedWorkspaces.first(where: { Self.tag($0) == tag }) {
            open(entry)
        } else if let entry = model.recentFolders.first(where: { Self.tag($0) == tag }) {
            open(entry)
        }
    }

    private func reveal(tag: String) {
        if let entry = model.savedWorkspaces.first(where: { Self.tag($0) == tag }) {
            model.revealInFinder(entry)
        } else if let entry = model.recentFolders.first(where: { Self.tag($0) == tag }) {
            model.revealInFinder(entry)
        }
    }

    private func remove(tag: String) {
        if let entry = model.savedWorkspaces.first(where: { Self.tag($0) == tag }) {
            model.remove(entry)
        } else if let entry = model.recentFolders.first(where: { Self.tag($0) == tag }) {
            model.remove(entry)
        }
        if selection == tag { selection = nil }
    }

    private func openSelectionOrFirst() {
        if let selection { return open(tag: selection) }
        if let first = savedRows.first { return open(first) }
        if let first = recentRows.first { open(first) }
    }

    private func open(_ entry: SavedWorkspaceEntry) {
        Task {
            guard let url = await model.resolve(entry) else {
                return model.presentMissing(entry.displayName)
            }
            if placement == .welcome, let session {
                session.openWorkspaceFile(at: url)
            } else {
                WorkspaceFileOpenRouter.open(url)
            }
        }
    }

    private func open(_ entry: RecentWorkspaceEntry) {
        guard let url = model.resolve(entry) else { return model.presentMissing(entry.displayName) }
        if placement == .welcome, let session {
            session.openLocalWorkspace(at: url)
        } else {
            WorkspaceFileOpenRouter.openFolder(url)
        }
    }
}

/// What one row shows, for a saved workspace or a recent folder.
struct WorkspacesListRowPresentation: Equatable {
    let name: String
    let symbolName: String
    let folderCountText: String
    let pathsText: String
    let lastOpened: Date

    static func saved(_ entry: SavedWorkspaceEntry) -> Self {
        let count = entry.folderPaths.count
        return Self(
            name: entry.displayName,
            symbolName: "square.stack.3d.up",
            folderCountText: count == 1 ? "1 folder" : "\(count) folders",
            pathsText: entry.folderPaths.map(Self.abbreviated).joined(separator: ", "),
            lastOpened: entry.lastOpened)
    }

    static func recent(_ entry: RecentWorkspaceEntry) -> Self {
        Self(
            name: entry.displayName,
            symbolName: "folder",
            folderCountText: "1 folder",
            pathsText: abbreviated(entry.rootPath),
            lastOpened: entry.lastOpened)
    }

    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

private struct WorkspacesListRow: View {
    let presentation: WorkspacesListRowPresentation
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(spacing: RafuMetrics.space2) {
            Image(systemName: presentation.symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(presentation.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                    Text(presentation.folderCountText)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.textMuted)
                        .lineLimit(1)
                }
                Text(presentation.pathsText)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(presentation.pathsText)
            }
            .layoutPriority(1)
            Spacer(minLength: RafuMetrics.space1)
            Text(presentation.lastOpened, format: .relative(presentation: .named))
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.textMuted)
                .lineLimit(1)
                .fixedSize()
            moreMenu
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the workspace")
        .accessibilityAction(named: "Open", onOpen)
        .accessibilityAction(named: "Reveal in Finder", onReveal)
        .accessibilityAction(named: "Remove from List", onRemove)
    }

    private var accessibilityLabel: String {
        "\(presentation.name), \(presentation.folderCountText), \(presentation.pathsText)"
    }

    @ViewBuilder
    private var actions: some View {
        Button("Open", action: onOpen)
        Button("Reveal in Finder", action: onReveal)
        Divider()
        Button("Remove from List", action: onRemove)
    }

    private var moreMenu: some View {
        Menu {
            actions
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(theme.palette.textSecondary)
        .fixedSize()
        .help("More actions for \(presentation.name)")
        .accessibilityLabel("More actions for \(presentation.name)")
    }
}

/// The "Workspaces" window (Window menu, ⇧⌘1). One per app; it lists the
/// same entries as the welcome screen.
struct WorkspacesWindowView: View {
    @AppStorage("themeChoice") private var themeChoice = RafuThemeChoice.system.rawValue
    @AppStorage("themeRevision") private var themeRevision = 0
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        WorkspacesWindowContent()
            .rafuTheme(theme)
            .preferredColorScheme(preferredColorScheme)
    }

    private var theme: RafuTheme {
        let _ = themeRevision
        return RafuThemeCatalog.resolved(identifier: themeChoice, systemScheme: systemScheme)
    }

    private var preferredColorScheme: ColorScheme? {
        RafuThemeChoice(rawValue: themeChoice) == .system ? nil : theme.colorScheme
    }
}

private struct WorkspacesWindowContent: View {
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space3) {
            HStack(spacing: RafuMetrics.space2) {
                Text("Workspaces")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: RafuMetrics.space2)
                Button("Open Workspace…", systemImage: "square.stack.3d.up") {
                    openWorkspacePanel()
                }
                .buttonStyle(RafuSecondaryButtonStyle())
                .help("Open a saved .rafuworkspace file")
            }
            WorkspacesListView(model: .shared, session: nil, placement: .window)
        }
        .padding(RafuMetrics.space4)
        .frame(minWidth: 460, minHeight: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.palette.editorBackground)
    }

    private func openWorkspacePanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Workspace"
        panel.prompt = "Open"
        panel.allowedContentTypes = [.rafuWorkspace]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            WorkspaceFileOpenRouter.open(url)
        }
    }
}
