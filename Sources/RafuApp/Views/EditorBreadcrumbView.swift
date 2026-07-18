import SwiftUI

/// Pure path-segment computation for the editor breadcrumb bar.
nonisolated enum EditorBreadcrumbPath {
    nonisolated struct Segment: Hashable, Sendable, Identifiable {
        enum Kind: Hashable, Sendable {
            case workspace
            case folder
            case file
            case collapsed
        }

        let title: String
        /// Absolute path used to reveal the segment in the file tree;
        /// `nil` for the collapsed "…" placeholder.
        let path: String?
        let kind: Kind

        var id: String { "\(kind)-\(path ?? title)" }
    }

    /// Builds workspace › folder… › file segments. Deep folder chains
    /// collapse the middle to "…", keeping the first folder plus the last
    /// `maxVisibleFolders - 1`.
    static func segments(
        workspaceName: String,
        rootPath: String,
        filePath: String,
        maxVisibleFolders: Int = 4
    ) -> [Segment] {
        let root = normalized(rootPath)
        guard filePath.hasPrefix(root + "/") else {
            return [
                Segment(
                    title: (filePath as NSString).lastPathComponent,
                    path: filePath,
                    kind: .file
                )
            ]
        }

        var components = filePath.dropFirst(root.count + 1)
            .split(separator: "/")
            .map(String.init)
        guard let fileName = components.popLast() else {
            return [Segment(title: workspaceName, path: root, kind: .workspace)]
        }

        var folders: [Segment] = []
        var currentPath = root
        for component in components {
            currentPath += "/" + component
            folders.append(Segment(title: component, path: currentPath, kind: .folder))
        }
        if folders.count > maxVisibleFolders, let first = folders.first {
            folders =
                [first, Segment(title: "…", path: nil, kind: .collapsed)]
                + folders.suffix(maxVisibleFolders - 1)
        }

        return [Segment(title: workspaceName, path: root, kind: .workspace)]
            + folders
            + [Segment(title: fileName, path: filePath, kind: .file)]
    }

    private static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// Themed path bar between the editor tab bar and the document content.
/// Folder segments reveal their location in the sidebar file tree.
struct EditorBreadcrumbView: View {
    @Environment(\.rafuTheme) private var theme
    @Bindable var session: WorkspaceSession
    let document: EditorDocument

    @State private var segments: [EditorBreadcrumbPath.Segment] = []

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.palette.textMuted)
                        .accessibilityHidden(true)
                }
                segmentView(segment)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.tabBarBackground)
        .overlay(alignment: .bottom) { Divider().overlay(theme.palette.borderSubtle) }
        .task(id: document.url) { rebuildSegments() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File path")
    }

    @ViewBuilder
    private func segmentView(_ segment: EditorBreadcrumbPath.Segment) -> some View {
        switch segment.kind {
        case .file:
            let icon = FileIconProvider.fileIcon(named: segment.title)
            HStack(spacing: 4) {
                FileIconView(icon: icon, size: 9)
                Text(segment.title)
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
            }
        case .collapsed:
            Text(segment.title)
                .foregroundStyle(theme.palette.textMuted)
                .accessibilityLabel("Collapsed folders")
        case .workspace, .folder:
            Button(segment.title) {
                if let path = segment.path {
                    session.revealInSidebar(path: path)
                }
            }
            .buttonStyle(BreadcrumbSegmentButtonStyle())
            .help("Reveal \(segment.title) in the sidebar")
            .accessibilityLabel("Reveal \(segment.title) in sidebar")
        }
    }

    private func rebuildSegments() {
        guard let rootURL = session.rootURL else {
            segments = [
                EditorBreadcrumbPath.Segment(
                    title: document.displayName,
                    path: document.url.path,
                    kind: .file
                )
            ]
            return
        }
        segments = EditorBreadcrumbPath.segments(
            workspaceName: session.descriptor?.displayName ?? rootURL.lastPathComponent,
            rootPath: rootURL.path,
            filePath: document.url.path
        )
    }
}

private struct BreadcrumbSegmentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        @Environment(\.rafuTheme) private var theme
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .lineLimit(1)
                .foregroundStyle(
                    isHovering ? theme.palette.textPrimary : theme.palette.textMuted
                )
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(
                            configuration.isPressed
                                ? theme.palette.selection
                                : isHovering ? theme.palette.chipBackground : .clear
                        )
                )
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
    }
}
