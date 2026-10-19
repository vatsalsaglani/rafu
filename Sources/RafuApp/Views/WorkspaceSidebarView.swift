import AppKit
import SwiftUI

struct WorkspaceSidebarView: View {
    @Bindable var session: WorkspaceSession
    @State private var renameNode: WorkspaceFileNode?
    @State private var renameText = ""
    /// Root sections the user collapsed (multi-folder workspaces only).
    /// Ephemeral window state; every root starts expanded.
    @State private var collapsedRootIDs: Set<UUID> = []

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            // Selection is drawn per row (see FileTreeRow) rather than via
            // `List(selection:)`. Driving the List's selection from the open
            // document's path renders a phantom highlighted row when that
            // file's ancestor folders are collapsed — SwiftUI's OutlineGroup
            // shows a selected id that isn't in the expanded set, overlapping
            // a real row.
            List {
                if session.isLoadingTree {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading files…")
                    }.foregroundStyle(theme.palette.textSecondary)
                } else if session.descriptor == nil {
                    Text("Open a folder to begin")
                        .foregroundStyle(theme.palette.textSecondary)
                } else if session.hasMultipleRoots, let primary = session.primaryRoot {
                    // More than one folder: each root is a top-level
                    // disclosure section, primary first. One folder looks
                    // exactly as before.
                    WorkspaceRootSection(
                        session: session, root: primary, tree: nil,
                        isExpanded: rootExpandedBinding(primary.id)
                    ) {
                        primaryRootItems
                    }
                    ForEach(session.additionalRootTrees) { tree in
                        WorkspaceRootSection(
                            session: session, root: tree.root, tree: tree,
                            isExpanded: rootExpandedBinding(tree.id)
                        ) {
                            WorkspaceRootTreeItems(
                                session: session, tree: tree, renameNode: $renameNode,
                                renameText: $renameText)
                        }
                    }
                } else {
                    primaryRootItems
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 24)
            .scrollContentBackground(.hidden)
            // Finder (or cross-workspace) drops on the tree background land in
            // the workspace root; folder rows below claim their own drops.
            .dropDestination(for: URL.self) { urls, _ in
                guard let root = session.rootURL else { return false }
                Task { await session.handleTreeDrop(urls, into: root) }
                return true
            }
            // ⌘C copies the selected tree item as a real file reference;
            // ⌘V pastes copied files or a clipboard image (screenshot) into
            // the selected folder. Both also exist as menu/context paths.
            .onCopyCommand {
                guard let path = session.selectedTreePath else { return [] }
                return [NSItemProvider(object: URL(filePath: path) as NSURL)]
            }
            .onPasteCommand(of: [.fileURL, .png, .tiff, .image]) { _ in
                session.pasteIntoSelectedFolder()
            }
        }
        .background(theme.palette.sidebarBackground)
        .navigationSplitViewColumnWidth(min: 190, ideal: 250, max: 380)
        .alert("Rename File", isPresented: renameBinding) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameNode = nil }
            Button("Rename") {
                guard let node = renameNode else { return }
                Task { await session.rename(node, to: renameText) }
            }
        } message: {
            Text("Enter a new name for \(renameNode?.name ?? "this item").")
        }
        .sheet(isPresented: creationBinding) {
            FileCreationSheet(session: session)
        }
    }

    /// Workspace name at the leading end (13 pt semibold, truncating) so
    /// several windows are told apart at a glance; the icon actions sit at the
    /// trailing end. "Filter Files" is the file-name filter (the Go to File
    /// palette); workspace-wide text search lives in the Search section of
    /// this same sidebar, reached from the Activity Rail.
    private var sidebarHeader: some View {
        HStack(spacing: 4) {
            Text(workspaceTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(workspaceTitle)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button("Filter Files", systemImage: "line.3.horizontal.decrease") {
                session.showCommandPalette(seed: "")
            }
            .buttonStyle(RafuIconButtonStyle(size: 24))
            .help("Filter Files (⌘P)")
            Button("New File", systemImage: "doc.badge.plus") {
                session.requestFileCreation(isDirectory: false)
            }
            .buttonStyle(RafuIconButtonStyle(size: 24))
            .help("New File")
            Button("New Folder", systemImage: "folder.badge.plus") {
                session.requestFileCreation(isDirectory: true)
            }
            .buttonStyle(RafuIconButtonStyle(size: 24))
            .help("New Folder")
            Button("Add Folder to Workspace", systemImage: "plus.rectangle.on.folder") {
                session.requestAddFolder()
            }
            .buttonStyle(RafuIconButtonStyle(size: 24))
            .help("Add Folder to Workspace…")
            .accessibilityLabel("Add Folder to Workspace")
            .disabled(session.rootURL == nil)
        }
        .padding(.horizontal, 10)
        // The header sits directly below the titlebar row.
        .padding(.top, 6)
        .padding(.bottom, 6)
        // The header's empty leading run doubles as a window-move surface
        // (`isMovable` is off; see WindowDragHandle). The icon buttons above
        // still win hit-testing.
        .background(WindowDragHandle())
    }

    private var workspaceTitle: String {
        session.descriptor?.displayName ?? "Files"
    }

    @ViewBuilder
    private var primaryRootItems: some View {
        ForEach(session.loadedChildren[""] ?? [], id: \.id) { node in
            WorkspaceFileTreeItem(
                session: session,
                node: node,
                renameNode: $renameNode,
                renameText: $renameText
            )
        }
    }

    private func rootExpandedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsedRootIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    collapsedRootIDs.remove(id)
                } else {
                    collapsedRootIDs.insert(id)
                }
            }
        )
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameNode != nil }, set: { if !$0 { renameNode = nil } })
    }

    private var creationBinding: Binding<Bool> {
        Binding(
            get: { session.pendingFileCreation != nil },
            set: { if !$0 { session.pendingFileCreation = nil } }
        )
    }
}

/// One row of the lazy file tree. A directory wraps its row in a
/// `DisclosureGroup` bound to `session.expandedDirectories`, loading its
/// children on demand (`session.loadChildrenIfNeeded`) the moment it is
/// expanded — including by `session.revealInSidebar`, which expands every
/// ancestor of a breadcrumb click. A file row is a leaf with no group.
///
/// `DisclosureGroup` recursion (instead of `OutlineGroup`) is required by
/// the lazy tree: `OutlineGroup` needs a fully materialized `children`
/// key path up front, which is exactly what per-directory loading avoids.
struct WorkspaceFileTreeItem: View {
    @Bindable var session: WorkspaceSession
    let node: WorkspaceFileNode
    @Binding var renameNode: WorkspaceFileNode?
    @Binding var renameText: String
    /// The additional root this row belongs to; nil for the primary root,
    /// whose tree state lives on the session.
    let rootTree: WorkspaceRootTree?

    /// Explicit init: the private `@State` below would otherwise make the
    /// synthesized memberwise init private, and tests build rows directly.
    init(
        session: WorkspaceSession,
        node: WorkspaceFileNode,
        renameNode: Binding<WorkspaceFileNode?>,
        renameText: Binding<String>,
        rootTree: WorkspaceRootTree? = nil
    ) {
        self.session = session
        self.node = node
        self._renameNode = renameNode
        self._renameText = renameText
        self.rootTree = rootTree
    }

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: expandedBinding) {
                directoryContent
            } label: {
                row
            }
            .listRowInsets(Self.rowInsets)
            .listRowSeparator(.hidden)
            .onChange(of: expandedBinding.wrappedValue, initial: true) { _, isExpanded in
                guard isExpanded else { return }
                if let rootTree {
                    rootTree.loadChildrenIfNeeded(node.relativePath)
                } else {
                    session.loadChildrenIfNeeded(node.relativePath)
                }
            }
        } else {
            row
                .listRowInsets(Self.rowInsets)
                .listRowSeparator(.hidden)
        }
    }

    /// Keeps every row clear of the sidebar's trailing edge: without an
    /// explicit inset, `.plain` list rows run flush against the split
    /// divider and long names visually cross it instead of truncating
    /// inside the pane.
    private static let rowInsets = EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 12)

    private var loadedChildren: [WorkspaceFileNode]? {
        if let rootTree { return rootTree.loadedChildren[node.relativePath] }
        return session.loadedChildren[node.relativePath]
    }

    @ViewBuilder
    private var directoryContent: some View {
        if let children = loadedChildren {
            if children.isEmpty {
                Text("No items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(children, id: \.id) { child in
                    WorkspaceFileTreeItem(
                        session: session,
                        node: child,
                        renameNode: $renameNode,
                        renameText: $renameText,
                        rootTree: rootTree
                    )
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading…").font(.caption)
            }
            .foregroundStyle(.secondary)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private var expandedBinding: Binding<Bool> {
        if let rootTree {
            return Binding(
                get: { rootTree.expandedDirectories.contains(node.relativePath) },
                set: { rootTree.setExpanded($0, node.relativePath) }
            )
        }
        return Binding(
            get: { session.expandedDirectories.contains(node.relativePath) },
            set: { isExpanded in
                if isExpanded {
                    session.expandedDirectories.insert(node.relativePath)
                } else {
                    session.expandedDirectories.remove(node.relativePath)
                }
            }
        )
    }

    /// A file row's drag carries BOTH the private editor-drag type (so it can
    /// split/open in the editor area) and a real file URL (so folder rows,
    /// other apps, and Finder can accept it). Directory rows drag as plain
    /// file URLs and accept drops: workspace items move, outside items copy.
    @ViewBuilder
    private var row: some View {
        let base =
            interactiveRow
            .contextMenu { contextMenu }
            .listRowBackground(Color.clear)
            .opacity(session.dragInFlight == dragToken ? 0.4 : 1)
        let icon = FileIconProvider.icon(for: node.url, isDirectory: node.isDirectory)
        let name = node.name
        if node.isDirectory {
            base
                .onDrag(
                    {
                        session.beginDragSourceTracking(dragToken)
                        return NSItemProvider(object: node.url as NSURL)
                    },
                    preview: { RafuDragPreviewLabel(icon: FileIconView(icon: icon), title: name) }
                )
                .dropDestination(for: URL.self) { urls, _ in
                    Task { await session.handleTreeDrop(urls, into: node.url) }
                    return true
                } isTargeted: {
                    isDropTargeted = $0
                }
        } else {
            base.onDrag(
                {
                    session.beginDragSourceTracking(dragToken)
                    let provider = session.beginEditorDrag(.file(path: node.url.path))
                    provider.registerObject(node.url as NSURL, visibility: .all)
                    return provider
                },
                preview: { RafuDragPreviewLabel(icon: FileIconView(icon: icon), title: name) }
            )
        }
    }

    @ViewBuilder
    private var interactiveRow: some View {
        if node.isDirectory {
            rowLabel
                .simultaneousGesture(
                    TapGesture().onEnded { activateRow() }
                )
        } else {
            Button(action: activateRow) {
                rowLabel
            }
            .buttonStyle(.plain)
        }
    }

    private var rowLabel: some View {
        FileTreeRow(
            node: node,
            isSelected: node.url.path == session.selectedTreePath,
            isDropTarget: isDropTargeted,
            gitBadge: session.gitTreeBadge(forRelativePath: node.relativePath, rootID: rootTree?.id)
        )
        .contentShape(.rect)
    }

    /// Only an explicit row action opens a file. Tree selection also changes
    /// during editor navigation and reveal, so observing that value would
    /// create a second, unwanted editor-navigation action.
    func activateRow() {
        session.selectedTreePath = node.url.path
        if !node.isDirectory { session.open(node) }
    }

    @State private var isDropTargeted = false
    /// This row's own identity for the dimmed source ghost while it is
    /// being dragged — stable for the row's lifetime, compared against
    /// `session.dragInFlight`.
    @State private var dragToken = RafuDragSourceToken()

    @ViewBuilder
    private var contextMenu: some View {
        if !node.isDirectory {
            Button("Open") { session.open(node) }
            Divider()
        } else {
            Button("New File…") { session.requestFileCreation(in: node.url, isDirectory: false) }
            Button("New Folder…") { session.requestFileCreation(in: node.url, isDirectory: true) }
            Divider()
        }
        Button("Rename…") {
            renameNode = node
            renameText = node.name
        }
        Divider()
        Button("Copy Relative Path") { copyString(node.relativePath) }
        Button("Copy Absolute Path") { copyString(node.url.path) }
        Button("Copy File") { copyFile(node.url) }
        Divider()
        Button("Paste") {
            session.pasteIntoSelectedFolder(
                target: node.isDirectory ? node.url : node.url.deletingLastPathComponent()
            )
        }
    }

    private func copyString(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func copyFile(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }
}

private struct FileCreationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: WorkspaceSession
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RafuSheetHeader(
                icon: request?.isDirectory == true ? "folder.badge.plus" : "doc.badge.plus",
                title: request?.isDirectory == true ? "New Folder" : "New File"
            )
            Text(request?.parentURL.path ?? "")
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            TextField("Name", text: $session.pendingFileName)
                .textFieldStyle(.plain)
                .rafuField(isFocused: isNameFocused)
                .focused($isNameFocused)
                .onSubmit { create() }
            HStack {
                Button("Cancel", role: .cancel) {
                    session.pendingFileCreation = nil
                    dismiss()
                }
                .buttonStyle(RafuSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") { create() }
                    .buttonStyle(RafuProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        session.pendingFileName.trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty)
            }
        }
        .padding(RafuMetrics.sheetPadding)
        .frame(width: 420)
    }

    private var request: WorkspaceSession.FileCreationRequest? { session.pendingFileCreation }

    private func create() {
        Task {
            await session.createPendingFileItem()
            if session.pendingFileCreation == nil { dismiss() }
        }
    }
}

private struct FileTreeRow: View {
    let node: WorkspaceFileNode
    var isSelected: Bool = false
    var isDropTarget: Bool = false
    var gitBadge: GitTreeBadge?
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        let icon = FileIconProvider.icon(for: node.url, isDirectory: node.isDirectory)
        HStack(spacing: 6) {
            Label {
                // Middle truncation keeps the extension visible when a long
                // name has to shrink; tail truncation used to hide ".md"/".sh"
                // right where the row met the divider.
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(nameColor)
            } icon: {
                FileIconView(icon: icon, size: 12)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            if let gitBadge {
                Text(gitBadge.shortCode)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(gitBadge.color(in: theme.palette))
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityLabel(gitBadge.accessibilityLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(
                    isDropTarget
                        ? theme.palette.accentSoft
                        : isSelected ? theme.palette.selection : Color.clear
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(
                    theme.palette.accent.opacity(isDropTarget ? 0.6 : 0),
                    lineWidth: 1
                )
        )
        .help(node.relativePath)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(node.isDirectory ? "Folder" : "Open file")
    }

    /// Tints the file name for statuses whose meaning is otherwise carried only
    /// by a color-coded letter, keeping the row legible while echoing the
    /// familiar editor convention. Untracked/added files read greenish, deleted
    /// files dimmed; everything else keeps the primary text color.
    private var nameColor: Color {
        guard let gitBadge, !node.isDirectory else { return theme.palette.textPrimary }
        switch gitBadge.kind {
        case .untracked, .added, .copied: return gitBadge.color(in: theme.palette)
        case .deleted: return theme.palette.textMuted
        default: return theme.palette.textPrimary
        }
    }
}
