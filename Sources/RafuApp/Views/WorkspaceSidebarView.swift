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
            .environment(\.defaultMinListRowHeight, FileTreeMetrics.rowHeight)
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
    /// several windows are told apart at a glance; two quiet icon actions sit
    /// at the trailing end. "Filter Files" is the file-name filter (the Go to
    /// File palette); workspace-wide text search lives in the Search section
    /// of this same sidebar, reached from the Activity Rail. The creation
    /// actions share one `plus` menu so the header is not a row of badges.
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
            Button("Filter Files", systemImage: "magnifyingglass") {
                session.showCommandPalette(seed: "")
            }
            .buttonStyle(RafuIconButtonStyle(size: 24))
            .help("Filter Files (⌘P)")
            newItemMenu
        }
        .padding(.horizontal, 10)
        // The header sits directly below the titlebar row; 10 pt above puts
        // the title's baseline on the first editor tab's text baseline.
        .padding(.top, 10)
        .padding(.bottom, 8)
        // The header's empty leading run doubles as a window-move surface
        // (`isMovable` is off; see WindowDragHandle). The icon buttons above
        // still win hit-testing.
        .background(WindowDragHandle())
    }

    /// New File, New Folder, and Add Folder to Workspace in one `plus` menu.
    /// The label is the shared icon button (textSecondary glyph, hover wash),
    /// so it carries no accent; each item keeps its own action, tooltip, and
    /// accessibility label.
    private var newItemMenu: some View {
        Menu {
            Button("New File…", systemImage: "doc.badge.plus") {
                session.requestFileCreation(isDirectory: false)
            }
            .help("New File")
            Button("New Folder…", systemImage: "folder.badge.plus") {
                session.requestFileCreation(isDirectory: true)
            }
            .help("New Folder")
            Divider()
            Button("Add Folder to Workspace…", systemImage: "plus.rectangle.on.folder") {
                session.requestAddFolder()
            }
            .help("Add Folder to Workspace…")
            .accessibilityLabel("Add Folder to Workspace")
            .disabled(session.rootURL == nil)
        } label: {
            Label("New", systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(RafuIconButtonStyle(size: 24))
        .menuIndicator(.hidden)
        .tint(theme.palette.textSecondary)
        .fixedSize()
        .help("New File, New Folder, or Add Folder to Workspace")
        .accessibilityLabel("New")
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
///
/// Every group uses `RafuFileTreeDisclosureStyle`, which emits the label and
/// the expanded children as flat List rows. The List therefore draws no
/// outline triangle and no outline indentation; each row draws its own
/// indent guides, 9 pt chevron, and icon from `depth`, which the recursion
/// passes down (the body never derives it from the path).
struct WorkspaceFileTreeItem: View {
    @Bindable var session: WorkspaceSession
    let node: WorkspaceFileNode
    @Binding var renameNode: WorkspaceFileNode?
    @Binding var renameText: String
    /// The additional root this row belongs to; nil for the primary root,
    /// whose tree state lives on the session.
    let rootTree: WorkspaceRootTree?
    /// Nesting level below the root (0 for a root's direct children). The
    /// parent passes `depth + 1` to its children.
    let depth: Int

    /// Explicit init: the private `@State` below would otherwise make the
    /// synthesized memberwise init private, and tests build rows directly.
    init(
        session: WorkspaceSession,
        node: WorkspaceFileNode,
        renameNode: Binding<WorkspaceFileNode?>,
        renameText: Binding<String>,
        rootTree: WorkspaceRootTree? = nil,
        depth: Int = 0
    ) {
        self.session = session
        self.node = node
        self._renameNode = renameNode
        self._renameText = renameText
        self.rootTree = rootTree
        self.depth = depth
    }

    var body: some View {
        if node.isDirectory {
            // Row traits and the load trigger sit on the label row, not on
            // the group: the flat style turns the group into several rows,
            // and a modifier on the group would apply to every one of them.
            DisclosureGroup(isExpanded: expandedBinding) {
                directoryContent
            } label: {
                row
                    .listRowInsets(Self.rowInsets)
                    .listRowSeparator(.hidden)
                    .onChange(of: expandedBinding.wrappedValue, initial: true) { _, isExpanded in
                        guard isExpanded else { return }
                        loadChildren()
                    }
            }
            .disclosureGroupStyle(RafuFileTreeDisclosureStyle())
        } else {
            row
                .listRowInsets(Self.rowInsets)
                .listRowSeparator(.hidden)
        }
    }

    /// Rows touch vertically so the indent guides run unbroken from row to
    /// row; the selection pill keeps its own 1 pt inset inside the row. The
    /// trailing inset keeps long names clear of the split divider: without
    /// it, `.plain` list rows run flush against the divider and names cross
    /// it instead of truncating inside the pane.
    static let rowInsets = EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 12)

    private var loadedChildren: [WorkspaceFileNode]? {
        if let rootTree { return rootTree.loadedChildren[node.relativePath] }
        return session.loadedChildren[node.relativePath]
    }

    private func loadChildren() {
        if let rootTree {
            rootTree.loadChildrenIfNeeded(node.relativePath)
        } else {
            session.loadChildrenIfNeeded(node.relativePath)
        }
    }

    @ViewBuilder
    private var directoryContent: some View {
        if let children = loadedChildren {
            if children.isEmpty {
                FileTreePlaceholderRow(depth: depth + 1) {
                    Text("No items").font(.caption)
                }
            } else {
                ForEach(children, id: \.id) { child in
                    WorkspaceFileTreeItem(
                        session: session,
                        node: child,
                        renameNode: $renameNode,
                        renameText: $renameText,
                        rootTree: rootTree,
                        depth: depth + 1
                    )
                }
            }
        } else {
            // The label's expansion observer normally starts the load; this
            // also covers a group expanded while its label row was off
            // screen (the List does not build rows it does not show).
            FileTreePlaceholderRow(depth: depth + 1) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Loading…").font(.caption)
                }
            }
            .onAppear { loadChildren() }
        }
    }

    private func toggleExpansion() {
        expandedBinding.wrappedValue.toggle()
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
                    preview: {
                        RafuDragPreviewLabel(icon: FileIconView(icon: icon), title: name)
                    }
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
                preview: {
                    RafuDragPreviewLabel(icon: FileIconView(icon: icon), title: name)
                }
            )
        }
    }

    @ViewBuilder
    private var interactiveRow: some View {
        if node.isDirectory {
            // The flat disclosure style leaves the List no outline row, so
            // the folder row itself carries what the outline gave: Full
            // Keyboard Access focus with Return/Space and Left/Right Arrow to
            // toggle, collapse, and expand, and one VoiceOver element that
            // announces the expansion state and toggles as its default action.
            let isExpanded = expandedBinding.wrappedValue
            rowLabel
                .simultaneousGesture(
                    TapGesture().onEnded { activateRow() }
                )
                .focusable(interactions: .activate)
                .onKeyPress(keys: [.return, .space, .leftArrow, .rightArrow]) { press in
                    switch press.key {
                    case .leftArrow: expandedBinding.wrappedValue = false
                    case .rightArrow: expandedBinding.wrappedValue = true
                    default: toggleExpansion()
                    }
                    return .handled
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityAction { toggleExpansion() }
                .accessibilityAction(named: isExpanded ? "Collapse" : "Expand") {
                    toggleExpansion()
                }
                .accessibilityAction(named: "Select") { activateRow() }
        } else {
            // Not a `Button`: its press tracking competes with the row's
            // `.onDrag` lift gesture for the same mouse-down, and a Button
            // fires on any mouse-up it still owns, so a failed drag reads
            // as a click that opens the file. Directory rows and
            // Terminals-panel rows already use plain gestures. One tap
            // handler (no `count: 2` sibling, so no double-click delay)
            // keeps single-click opening; the modifiers below restore what
            // `Button` gave for free: Full Keyboard Access focus
            // (activation-only, so a click never moves focus), Return/Space,
            // and one VoiceOver button element with a default action.
            rowLabel
                .onTapGesture(perform: activateRow)
                .focusable(interactions: .activate)
                .onKeyPress(keys: [.return, .space]) { _ in
                    activateRow()
                    return .handled
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { activateRow() }
        }
    }

    private var rowLabel: some View {
        FileTreeRow(
            node: node,
            depth: depth,
            isExpanded: node.isDirectory ? expandedBinding.wrappedValue : nil,
            onToggleDisclosure: toggleExpansion,
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

/// File-tree geometry shared by rows, guides, and placeholders. One indent
/// step equals the chevron cell, so a child's guide (at `level * indentStep
/// + indentStep / 2`) runs straight down from its parent's chevron.
nonisolated enum FileTreeMetrics {
    static let rowHeight: CGFloat = 26
    static let indentStep: CGFloat = 14
    static let selectionRadius: CGFloat = 6
    /// Vertical inset of the selection pill inside the touching rows.
    static let selectionInset: CGFloat = 1
}

/// Emits a lazily loaded directory as flat List rows: the label row, then
/// the children while expanded. The label row draws its own chevron, indent,
/// and guides (`FileTreeRow`), so this style draws nothing itself. Expansion
/// still flows through the group's `isExpanded` binding, which is what
/// starts the per-directory load.
struct RafuFileTreeDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
        if configuration.isExpanded {
            configuration.content
        }
    }
}

/// One 1 pt indent guide per ancestor level, each centred in an
/// `indentStep` cell. The innermost guide can draw stronger, beside the
/// selected child.
private struct FileTreeIndentGuides: View {
    let depth: Int
    var emphasizesInnermost = false
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<depth, id: \.self) { level in
                Rectangle()
                    .fill(
                        emphasizesInnermost && level == depth - 1
                            ? theme.palette.borderStrong : theme.palette.borderSubtle
                    )
                    .frame(width: 1)
                    .frame(width: FileTreeMetrics.indentStep)
            }
        }
        .frame(height: FileTreeMetrics.rowHeight)
        .accessibilityHidden(true)
    }
}

/// The 9 pt disclosure chevron in its 14 pt cell. It rotates without motion
/// under Reduce Motion. VoiceOver reaches the toggle through the folder
/// row's element, so the glyph itself is hidden.
private struct FileTreeDisclosureChevron: View {
    let isExpanded: Bool
    let toggle: () -> Void
    @Environment(\.rafuTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(theme.palette.textMuted)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(reduceMotion ? nil : RafuMotion.pressRelease, value: isExpanded)
            .frame(width: FileTreeMetrics.indentStep, height: FileTreeMetrics.rowHeight)
            .contentShape(.rect)
            .onTapGesture(perform: toggle)
            .accessibilityHidden(true)
    }
}

/// A "Loading…" or "No items" row, indented and guided like a child row.
private struct FileTreePlaceholderRow<Content: View>: View {
    let depth: Int
    @ViewBuilder let content: Content
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            FileTreeIndentGuides(depth: depth)
            content
                .foregroundStyle(theme.palette.textSecondary)
                .padding(.leading, FileTreeMetrics.indentStep + 2)
            Spacer(minLength: 0)
        }
        .frame(height: FileTreeMetrics.rowHeight)
        .listRowInsets(WorkspaceFileTreeItem.rowInsets)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

private struct FileTreeRow: View {
    let node: WorkspaceFileNode
    var depth: Int = 0
    /// nil for a file; a folder's expansion state otherwise.
    var isExpanded: Bool?
    var onToggleDisclosure: () -> Void = {}
    var isSelected: Bool = false
    var isDropTarget: Bool = false
    var gitBadge: GitTreeBadge?
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        let icon = FileIconProvider.icon(for: node.url, isDirectory: node.isDirectory)
        HStack(spacing: 0) {
            FileTreeIndentGuides(depth: depth, emphasizesInnermost: isSelected)
            HStack(spacing: 0) {
                // A file keeps the empty chevron cell, so file and folder
                // icons at one depth share a column.
                if let isExpanded {
                    FileTreeDisclosureChevron(isExpanded: isExpanded, toggle: onToggleDisclosure)
                } else {
                    Color.clear
                        .frame(width: FileTreeMetrics.indentStep)
                        .accessibilityHidden(true)
                }
                FileIconView(icon: icon, size: 12)
                    .padding(.leading, 2)
                    .accessibilityHidden(true)
                // Middle truncation keeps the extension visible when a long
                // name has to shrink; tail truncation used to hide ".md"/".sh"
                // right where the row met the divider.
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(nameColor)
                    .padding(.leading, 6)
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
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: FileTreeMetrics.rowHeight - 2 * FileTreeMetrics.selectionInset)
            .background(
                RoundedRectangle(cornerRadius: FileTreeMetrics.selectionRadius, style: .continuous)
                    .fill(
                        isDropTarget
                            ? theme.palette.accentSoft
                            : isSelected ? theme.palette.selection : Color.clear
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: FileTreeMetrics.selectionRadius, style: .continuous)
                    .strokeBorder(
                        theme.palette.accent.opacity(isDropTarget ? 0.6 : 0),
                        lineWidth: 1
                    )
            )
        }
        .frame(height: FileTreeMetrics.rowHeight)
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
