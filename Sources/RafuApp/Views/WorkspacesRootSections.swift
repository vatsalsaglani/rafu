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
    /// Whether Source Control shows a repository of this root while the
    /// workspace has more than one repository.
    private var isSourceControlRoot: Bool {
        session.gitRepositories.count > 1 && session.selectedGitRepository?.rootID == root.id
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

/// Source Control's Repositories section: one row per Git repository of
/// the workspace (each root that is a repository, and the nested
/// repositories directly inside a root). The selected row drives Changes,
/// History, and Branches below it. With one repository in a multi-folder
/// workspace it is a single header line; a one-folder workspace with one
/// repository shows nothing extra.
struct SourceControlRepositoriesSection: View {
    @Bindable var session: WorkspaceSession

    @Environment(\.rafuTheme) private var theme
    @State private var isExpanded = true

    /// Rows shown before the list scrolls.
    private static let visibleRowLimit = 6

    var body: some View {
        let repositories = session.gitRepositories
        if repositories.count > 1 {
            VStack(alignment: .leading, spacing: 0) {
                header(count: repositories.count)
                if isExpanded {
                    rows(repositories)
                }
            }
            .padding(.horizontal, RafuMetrics.space1 + 2)
            .padding(.bottom, isExpanded ? RafuMetrics.space1 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { divider }
            .task(id: repositories.map(\.id)) { session.repositoriesSectionDidAppear() }
            .onDisappear { session.repositoriesSectionDidDisappear() }
        } else if let only = repositories.first, session.hasMultipleRoots {
            SourceControlRepositoryHeaderLine(
                repository: only, summary: session.gitRepositorySummary(for: only.id)
            )
            .padding(.horizontal, RafuMetrics.space1 + 2)
            .overlay(alignment: .bottom) { divider }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.palette.borderSubtle)
            .frame(height: RafuMetrics.hairline)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func header(count: Int) -> some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: RafuMetrics.space1) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
                    .accessibilityHidden(true)
                Text("Repositories")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(theme.palette.textMuted)
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.palette.textSecondary)
            .frame(height: 24)
            .padding(.horizontal, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide repositories" : "Show repositories")
        .accessibilityLabel("Repositories, \(count)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func rows(_ repositories: [GitRepositoryRef]) -> some View {
        let selectedID = session.effectiveSourceControlRepositoryID
        let listedRootIDs = Set(repositories.filter { !$0.isNested }.map(\.rootID))
        let content = VStack(spacing: 0) {
            ForEach(repositories) { repository in
                SourceControlRepositoryRow(
                    repository: repository,
                    summary: session.gitRepositorySummary(for: repository.id),
                    isSelected: repository.id == selectedID,
                    isIndented: repository.isNested && listedRootIDs.contains(repository.rootID),
                    onSelect: { session.selectGitRepository(repository.id) })
            }
        }
        if repositories.count > Self.visibleRowLimit {
            ScrollView(.vertical) { content }
                .scrollIndicators(.automatic)
                .frame(
                    height: FileTreeMetrics.rowHeight * (CGFloat(Self.visibleRowLimit) + 0.5))
        } else {
            content
        }
    }
}

/// One repository row: 26 pt, like a Files-tree row, with the same
/// selection pill. Branch and counts are words and symbols, never color
/// alone.
private struct SourceControlRepositoryRow: View {
    let repository: GitRepositoryRef
    let summary: GitRepositorySummary?
    let isSelected: Bool
    let isIndented: Bool
    let onSelect: () -> Void

    @Environment(\.rafuTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        let presentation = GitRepositoryRowPresentation(repository: repository, summary: summary)
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "folder.fill" : "folder")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(
                        isSelected ? theme.palette.accent : theme.palette.textSecondary
                    )
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(repository.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if let branch = presentation.branchText {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9, weight: .medium))
                            .accessibilityHidden(true)
                        Text(branch)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.textMuted)
                }
                Spacer(minLength: 4)
                trailing(presentation)
            }
            .padding(.leading, isIndented ? FileTreeMetrics.indentStep + 6 : 6)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: FileTreeMetrics.rowHeight - 2 * FileTreeMetrics.selectionInset)
            .background(
                RoundedRectangle(cornerRadius: FileTreeMetrics.selectionRadius, style: .continuous)
                    .fill(
                        isSelected
                            ? theme.palette.selection
                            : isHovered ? theme.palette.hover : Color.clear)
            )
            .frame(height: FileTreeMetrics.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(presentation.help)
        .contextMenu {
            Button("Show in Source Control", action: onSelect)
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([repository.url])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(repository.url.path, forType: .string)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Repository \(repository.displayName)")
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityHint("Shows this repository in Source Control")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func trailing(_ presentation: GitRepositoryRowPresentation) -> some View {
        HStack(spacing: 5) {
            if let ahead = presentation.aheadText {
                Label(ahead, systemImage: "arrow.up")
                    .labelStyle(CompactCountLabelStyle())
            }
            if let behind = presentation.behindText {
                Label(behind, systemImage: "arrow.down")
                    .labelStyle(CompactCountLabelStyle())
            }
            if let conflicts = presentation.conflictText {
                HStack(spacing: 2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8.5, weight: .semibold))
                    Text(conflicts)
                }
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(theme.palette.gitConflict)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(theme.palette.gitConflict.opacity(0.14)))
            }
            if let changes = presentation.changeText {
                Text(changes)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.palette.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(theme.palette.textMuted.opacity(0.16)))
            }
        }
        .font(.system(size: 10.5).monospacedDigit())
        .foregroundStyle(theme.palette.textMuted)
        .lineLimit(1)
        .fixedSize()
    }
}

/// "↑2" with a small symbol and a monospaced count.
private struct CompactCountLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 1) {
            configuration.icon.font(.system(size: 8.5, weight: .semibold))
            configuration.title
        }
    }
}

/// The single header line for a multi-folder workspace with one repository.
private struct SourceControlRepositoryHeaderLine: View {
    let repository: GitRepositoryRef
    let summary: GitRepositorySummary?

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        let presentation = GitRepositoryRowPresentation(repository: repository, summary: summary)
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(repository.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Only repository")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.palette.textMuted)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: FileTreeMetrics.rowHeight)
        .help(presentation.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Repository \(repository.displayName), the only repository")
        .accessibilityAddTraits(.isHeader)
    }
}

/// Pure text for a repository row, kept out of the view so it is testable.
nonisolated struct GitRepositoryRowPresentation: Equatable {
    let branchText: String?
    let aheadText: String?
    let behindText: String?
    let changeText: String?
    let conflictText: String?
    let accessibilityValue: String
    let help: String

    init(repository: GitRepositoryRef, summary: GitRepositorySummary?) {
        guard let summary else {
            branchText = nil
            aheadText = nil
            behindText = nil
            changeText = nil
            conflictText = nil
            accessibilityValue = "Loading status"
            help = repository.url.path
            return
        }
        let branch = summary.isDetached ? "detached" : summary.branch
        branchText = branch
        aheadText = summary.aheadCount > 0 ? "\(summary.aheadCount)" : nil
        behindText = summary.behindCount > 0 ? "\(summary.behindCount)" : nil
        changeText = summary.changeCount > 0 ? "\(summary.changeCount)" : nil
        conflictText = summary.conflictCount > 0 ? "\(summary.conflictCount)" : nil
        var parts = [summary.isDetached ? "Detached HEAD" : "Branch \(summary.branch)"]
        parts.append(Self.count(summary.changeCount, "change", "changes", none: "No changes"))
        if summary.conflictCount > 0 {
            parts.append(Self.count(summary.conflictCount, "conflict", "conflicts"))
        }
        if summary.aheadCount > 0 { parts.append("\(summary.aheadCount) ahead") }
        if summary.behindCount > 0 { parts.append("\(summary.behindCount) behind") }
        accessibilityValue = parts.joined(separator: ", ")
        help = "\(repository.url.path)\n\(accessibilityValue)"
    }

    private static func count(
        _ value: Int, _ singular: String, _ plural: String, none: String? = nil
    ) -> String {
        if value == 0, let none { return none }
        return "\(value) \(value == 1 ? singular : plural)"
    }
}
