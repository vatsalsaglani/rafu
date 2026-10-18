import AppKit
import RafuCore
import SwiftUI

/// One root of a multi-folder workspace in the Files tree: a top-level
/// disclosure section with the folder's label, and a context menu with
/// Add Folder, Remove Folder from Workspace, Reveal in Finder, Copy Path, and
/// the Source Control root choice. The primary root cannot be removed.
struct WorkspaceRootSection<Content: View>: View {
    @Bindable var session: WorkspaceSession
    let root: WorkspaceRoot
    /// nil for the primary root.
    let tree: WorkspaceRootTree?
    @Binding var isExpanded: Bool
    let content: Content

    @Environment(\.rafuTheme) private var theme
    @State private var isDropTargeted = false

    init(
        session: WorkspaceSession, root: WorkspaceRoot, tree: WorkspaceRootTree?,
        isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content
    ) {
        self.session = session
        self.root = root
        self.tree = tree
        self._isExpanded = isExpanded
        self.content = content()
    }

    private var isPrimary: Bool { tree == nil }
    private var label: String { session.rootDisplayNames[root.id] ?? root.name }
    private var rootURL: URL? { session.url(forRoot: root.id) }
    private var isSourceControlRoot: Bool {
        session.effectiveSourceControlRootID == root.id
            && session.sourceControlRootChoices.count > 1
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
        } label: {
            header
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 1, trailing: 12))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: isPrimary ? "folder.fill" : "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
                .accessibilityHidden(true)
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if isPrimary {
                Text("Primary")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.palette.textMuted)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 4)
            if isSourceControlRoot {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.palette.textMuted)
                    .help("Source Control shows this folder")
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isDropTargeted ? theme.palette.accentSoft : Color.clear)
        )
        .contentShape(.rect)
        .help(root.path)
        .contextMenu { menu }
        .dropDestination(for: URL.self) { urls, _ in
            guard let rootURL else { return false }
            Task { await session.handleTreeDrop(urls, into: rootURL) }
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isPrimary ? "Folder \(label), primary" : "Folder \(label)"
        )
        .accessibilityHint(isExpanded ? "Collapses the folder" : "Expands the folder")
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var menu: some View {
        Button("New File…") {
            if let rootURL { session.requestFileCreation(in: rootURL, isDirectory: false) }
        }
        Button("New Folder…") {
            if let rootURL { session.requestFileCreation(in: rootURL, isDirectory: true) }
        }
        Divider()
        Button("Add Folder to Workspace…") { session.requestAddFolder() }
        Button("Remove Folder from Workspace") { session.removeFolder(root.id) }
            .disabled(isPrimary)
            .help(
                isPrimary
                    ? "The primary folder cannot be removed"
                    : "Removes the folder from this workspace. Its files stay on disk.")
        Divider()
        if session.sourceControlRootChoices.contains(where: { $0.id == root.id }) {
            Button("Show in Source Control") {
                session.selectSourceControlRoot(root.id)
                session.navigatorMode = .sourceControl
            }
            Divider()
        }
        Button("Reveal in Finder") {
            if let rootURL { NSWorkspace.shared.activateFileViewerSelecting([rootURL]) }
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(root.path, forType: .string)
        }
    }
}

/// The lazily listed top level of an additional root.
struct WorkspaceRootTreeItems: View {
    @Bindable var session: WorkspaceSession
    let tree: WorkspaceRootTree
    @Binding var renameNode: WorkspaceFileNode?
    @Binding var renameText: String

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        if let children = tree.loadedChildren[""] {
            if let error = tree.loadError {
                message(error)
            } else if children.isEmpty {
                message("No items")
            } else {
                ForEach(children, id: \.id) { node in
                    WorkspaceFileTreeItem(
                        session: session, node: node, renameNode: $renameNode,
                        renameText: $renameText, rootTree: tree)
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading…").font(.caption)
            }
            .foregroundStyle(theme.palette.textSecondary)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .onAppear { tree.loadChildrenIfNeeded("") }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(theme.palette.textSecondary)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/// Source Control's folder picker for a multi-folder workspace. Shown only
/// when more than one root is a Git work tree; the primary root is the
/// default.
struct WorkspaceSourceControlRootPicker: View {
    @Bindable var session: WorkspaceSession

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        let choices = session.sourceControlRootChoices
        if choices.count > 1 {
            let names = session.rootDisplayNames
            let current = session.effectiveSourceControlRootID
            let currentName = choices.first { $0.id == current }.map { names[$0.id] ?? $0.name }
            HStack(spacing: RafuMetrics.space2) {
                Text("Folder")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.palette.textMuted)
                    .accessibilityHidden(true)
                Menu {
                    ForEach(choices) { root in
                        Button {
                            session.selectSourceControlRoot(root.id)
                        } label: {
                            if root.id == current {
                                Label(names[root.id] ?? root.name, systemImage: "checkmark")
                            } else {
                                Text(names[root.id] ?? root.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .medium))
                            .accessibilityHidden(true)
                        Text(currentName ?? "Primary folder")
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(theme.palette.textPrimary)
                }
                .menuStyle(.borderlessButton)
                .tint(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .help("Choose the folder Source Control shows")
                .accessibilityLabel("Source Control folder")
                .accessibilityValue(currentName ?? "Primary folder")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, RafuMetrics.utilityBodyInset)
            .padding(.vertical, RafuMetrics.space1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
