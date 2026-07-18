import AppKit
import SwiftUI

struct WorkspaceSidebarView: View {
    @Bindable var session: WorkspaceSession
    @State private var renameNode: WorkspaceFileNode?
    @State private var renameText = ""

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
                } else {
                    ForEach(session.loadedChildren[""] ?? [], id: \.id) { node in
                        WorkspaceFileTreeItem(
                            session: session,
                            node: node,
                            renameNode: $renameNode,
                            renameText: $renameText
                        )
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(theme.palette.sidebarBackground.opacity(0.85))
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

    private var sidebarHeader: some View {
        HStack(spacing: 4) {
            Text(session.descriptor?.displayName ?? "Files")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.palette.textMuted)
                .textCase(.uppercase)
                .kerning(0.6)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Search Workspace", systemImage: "magnifyingglass") {
                session.navigatorMode = .search
            }
            .buttonStyle(RafuIconButtonStyle(size: 24))
            .help("Search Workspace")
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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
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
private struct WorkspaceFileTreeItem: View {
    @Bindable var session: WorkspaceSession
    let node: WorkspaceFileNode
    @Binding var renameNode: WorkspaceFileNode?
    @Binding var renameText: String

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: expandedBinding) {
                directoryContent
            } label: {
                row
            }
            .onChange(of: expandedBinding.wrappedValue, initial: true) { _, isExpanded in
                if isExpanded { session.loadChildrenIfNeeded(node.relativePath) }
            }
        } else {
            row
        }
    }

    @ViewBuilder
    private var directoryContent: some View {
        if let children = session.loadedChildren[node.relativePath] {
            if children.isEmpty {
                Text("No items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(children, id: \.id) { child in
                    WorkspaceFileTreeItem(
                        session: session,
                        node: child,
                        renameNode: $renameNode,
                        renameText: $renameText
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
        }
    }

    private var expandedBinding: Binding<Bool> {
        Binding(
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

    /// A file row gets `.onDrag` so it can be dropped into the editor area
    /// (same private drag type and live preview as tab drags); directories
    /// never drag. The single- and double-click gestures are unaffected.
    @ViewBuilder
    private var row: some View {
        let base =
            FileTreeRow(
                node: node,
                isSelected: node.url.path == session.selectedTreePath,
                gitBadge: session.gitTreeBadges[node.relativePath]
            )
            .contentShape(.rect)
            .onTapGesture(count: 2) { session.open(node) }
            .simultaneousGesture(
                TapGesture(count: 1).onEnded {
                    session.selectedTreePath = node.url.path
                }
            )
            .contextMenu { contextMenu }
            .listRowBackground(Color.clear)
        if node.isDirectory {
            base
        } else {
            base.onDrag { session.beginEditorDrag(.file(path: node.url.path)) }
        }
    }

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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(
                request?.isDirectory == true ? "New Folder" : "New File",
                systemImage: request?.isDirectory == true ? "folder.badge.plus" : "doc.badge.plus"
            )
            .font(.headline)
            Text(request?.parentURL.path ?? "")
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            TextField("Name", text: $session.pendingFileName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { create() }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    session.pendingFileCreation = nil
                    dismiss()
                }
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        session.pendingFileName.trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty)
            }
        }
        .padding(22)
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
    var gitBadge: GitTreeBadge?
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        let icon = FileIconProvider.icon(for: node.url, isDirectory: node.isDirectory)
        HStack(spacing: 6) {
            Label {
                Text(node.name)
                    .lineLimit(1)
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
                    .accessibilityLabel(gitBadge.accessibilityLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? theme.palette.selection : Color.clear)
        )
        .help(node.relativePath)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(node.isDirectory ? "Folder" : "Double-click to open")
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
