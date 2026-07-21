import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EditorCanvasView: View {
    @Environment(\.rafuTheme) private var theme
    @Bindable var session: WorkspaceSession
    let openFolder: () -> Void

    var body: some View {
        ZStack {
            if session.descriptor == nil {
                WorkspaceWelcomeView(session: session, openFolder: openFolder)
            } else if !session.hasAnyEditorTabs && session.gitOpenDiff == nil
                && session.gitOpenBlame == nil
            {
                EmptyEditorView(
                    workspaceName: session.descriptor?.displayName ?? "Workspace",
                    session: session
                )
            } else if let blame = session.gitOpenBlame,
                let document = session.selectedDocument
            {
                GitStandaloneBlameCanvas(
                    blame: blame,
                    fileName: document.displayName,
                    close: session.closeBlame
                )
            } else if let openDiff = session.gitOpenDiff, session.selectedDocumentID == nil {
                GitStandaloneDiffCanvas(openDiff: openDiff, session: session)
            } else {
                EditorLayoutTreeView(node: session.editorLayout.root, session: session)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.editorBackground)
        .onChange(of: session.selectedDocumentID) { oldValue, newValue in
            if session.gitOpenBlame != nil, oldValue != newValue {
                session.closeBlame()
            }
        }
        .onChange(of: session.rootURL) { oldValue, newValue in
            if session.gitOpenBlame != nil, oldValue != newValue {
                session.closeBlame()
            }
        }
        .alert("Save changes before closing?", isPresented: closeAlertBinding) {
            Button("Save and Close") { session.saveAndClosePendingDocument() }
            Button("Discard", role: .destructive) { session.discardAndClosePendingDocument() }
            Button("Cancel", role: .cancel) { session.pendingCloseDocument = nil }
        } message: {
            Text("\(session.pendingCloseDocument?.displayName ?? "This file") has unsaved changes.")
        }
    }

    private var closeAlertBinding: Binding<Bool> {
        Binding(
            get: { session.pendingCloseDocument != nil },
            set: { if !$0 { session.pendingCloseDocument = nil } }
        )
    }
}

private struct EditorLayoutTreeView: View {
    let node: EditorLayoutNode
    @Bindable var session: WorkspaceSession

    var body: some View {
        renderedNode
    }

    private var renderedNode: AnyView {
        switch node {
        case .group(let group):
            AnyView(EditorGroupView(group: group, session: session))
        case .split(_, let axis, _, let first, let second):
            switch axis {
            case .horizontal:
                AnyView(
                    HSplitView {
                        EditorLayoutTreeView(node: first, session: session).frame(minWidth: 220)
                        EditorLayoutTreeView(node: second, session: session).frame(minWidth: 220)
                    })
            case .vertical:
                AnyView(
                    VSplitView {
                        EditorLayoutTreeView(node: first, session: session).frame(minHeight: 150)
                        EditorLayoutTreeView(node: second, session: session).frame(minHeight: 150)
                    })
            }
        }
    }
}

private struct EditorGroupView: View {
    @State private var hoveredDropEdge: EditorSplitEdge?
    @State private var isDropTargeted = false

    let group: EditorGroupState
    @Bindable var session: WorkspaceSession

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                EditorGroupTabBar(group: group, session: session)
                Divider()
                if let document = selectedDocument {
                    EditorBreadcrumbView(session: session, document: document)
                }
                if isFindPresented, let document = selectedDocument {
                    DocumentFindBar(
                        state: session.findState(for: document),
                        showsReplace: $session.isDocumentReplacePresented,
                        close: session.dismissDocumentFind
                    )
                    Divider()
                }
                if let terminalController = selectedTerminalController {
                    // Issue #4: a terminal tab's content replaces the
                    // document ZStack entirely while selected — only one
                    // terminal is ever mounted at a time per group, since
                    // `WorkspaceTerminalController.makeOrReuseView` reuses
                    // the same live `LocalProcessTerminalView` (and its
                    // scrollback) across remounts, unlike a document's
                    // bounded-working-set hibernation.
                    EditorTerminalTabContent(controller: terminalController)
                } else if loadedDocuments.isEmpty {
                    ContentUnavailableView(
                        "Empty Editor Group",
                        systemImage: "rectangle.split.2x1",
                        description: Text("Drag a tab here or open a file from the sidebar.")
                    )
                } else {
                    // The bounded working set: every LOADED document in this
                    // group stays mounted so TextKit keeps owning its live
                    // text (dirty non-visible buffers included — the
                    // data-safety invariant). Only the selected editor is
                    // visible and interactive; the rest are inert (invisible,
                    // no hit testing, no first-responder path, accessibility
                    // hidden, no drop forwarding) but mounted. Hibernated
                    // documents are omitted entirely and remount from disk on
                    // reselection.
                    ZStack {
                        ForEach(loadedDocuments) { document in
                            let isActive = document.id == selectedDocument?.id
                            EditorDocumentView(
                                document: document,
                                findState: session.findState(for: document),
                                gitLineChangesProvider: { [weak session, weak document] in
                                    guard let session, let document else { return nil }
                                    return await session.gutterLineChanges(for: document)
                                },
                                requestGitRefresh: { [weak session] in
                                    guard let session else { return }
                                    Task { await session.refreshGit() }
                                },
                                dropForwarding: isActive ? dropForwarding : nil,
                                navigate: { [weak session] kind in
                                    session?.navigate(kind: kind)
                                },
                                hover: { [weak session, weak document] offset in
                                    guard let session, let document else { return nil }
                                    return await session.hoverInfo(
                                        at: document.url, utf16Offset: offset)
                                },
                                inlineBlameEnabled: session.isInlineBlameEnabled,
                                inlineBlameProvider: { [weak session, weak document] in
                                    guard let session, let document else { return nil }
                                    return await session.inlineBlame(for: document)
                                },
                                fileBlameAnnotationsEnabled: session.isFileBlameAnnotationsEnabled,
                                fileBlameAnnotationsProvider: { [weak session, weak document] in
                                    guard let session, let document else { return nil }
                                    return await session.fileBlameAnnotations(for: document)
                                },
                                aiCompletionEnabled: session.isAICompletionEnabled,
                                aiCompletionProvider: {
                                    [weak session, weak document] prefix, suffix in
                                    guard let session, let document else { return nil }
                                    return await session.inlineCompletion(
                                        prefix: prefix, suffix: suffix,
                                        fileName: document.displayName)
                                },
                                gitPeekActions: gitPeekActions(for: document)
                            )
                            .id(document.id)
                            .opacity(isActive ? 1 : 0)
                            .allowsHitTesting(isActive)
                            .accessibilityHidden(!isActive)
                        }
                    }
                }
            }
            .overlay {
                if isDropTargeted {
                    EditorSplitPreviewOverlay(edge: hoveredDropEdge)
                }
            }
            .onDrop(
                of: [.rafuEditorDrag],
                delegate: EditorDropDelegate(
                    groupID: group.id,
                    size: proxy.size,
                    hoveredEdge: $hoveredDropEdge,
                    isTargeted: $isDropTargeted,
                    session: session
                )
            )
        }
    }

    private var selectedTab: EditorTabState? {
        guard let selectedTabID = group.selectedTabID else { return nil }
        return group.tabs.first(where: { $0.id == selectedTabID })
    }

    private var selectedDocument: EditorDocument? {
        guard let selectedTab else { return nil }
        return session.document(for: selectedTab)
    }

    /// The live terminal session behind the selected `.terminal` tab, or
    /// `nil` when the selection is a file tab (or the referenced session no
    /// longer exists — e.g. it was closed by another path).
    private var selectedTerminalController: WorkspaceTerminalController? {
        guard case .terminal(let sessionID) = selectedTab?.resource else { return nil }
        return session.terminal.sessions.first { $0.id == sessionID }
    }

    /// This group's documents whose editor should stay mounted. The selected
    /// tab's document is always loaded (visible documents never hibernate), so
    /// a non-empty group always yields a non-empty set that includes the
    /// selected document.
    private var loadedDocuments: [EditorDocument] {
        group.tabs
            .compactMap { session.document(for: $0) }
            .filter { $0.loadState == .loaded }
    }

    private var isFindPresented: Bool {
        session.isDocumentFindPresented && session.isFocusedGroup(group.id)
    }

    /// GX2 hunk-peek/blame-hover wiring for `document`, threaded into
    /// `CodeEditorView`. Stage Hunk and the working-tree diff provider go
    /// through `WorkspaceSession`'s peek-scoped methods; Open Full Diff maps
    /// to the standalone diff canvas; Show in History jumps the History
    /// selection (and reveals Source Control if it isn't already open);
    /// Open Blame Canvas reuses the existing read-only blame path.
    private func gitPeekActions(for document: EditorDocument) -> GitPeekActions {
        GitPeekActions(
            workingTreeDiffProvider: { [weak session, weak document] in
                guard let session, let document else { return nil }
                return await session.workingTreeDiff(for: document)
            },
            stageHunk: { [weak session] hunk, diff in
                await session?.stagePeekHunk(hunk, in: diff)
            },
            openFullDiff: { [weak session, weak document] in
                guard let session, let document else { return }
                session.openWorkingTreeDiff(for: document)
            },
            showCommitInHistory: { [weak session] line in
                guard let session else { return }
                session.navigatorMode = .sourceControl
                session.gitInspectorSection = .history
                session.gitSelectedHistoryCommitID = line.commitID
                if let commit = session.gitHistoryPage?.commits.first(where: {
                    $0.id == line.commitID
                }) {
                    Task { await session.gitSelectHistoryCommit(commit) }
                }
            },
            openBlameCanvas: { [weak session] in
                Task { await session?.openBlameForSelectedFile() }
            },
            isBusy: { [weak session] in
                session?.isGitBusy == true || session?.isGitHunkActionBusy == true
            }
        )
    }

    /// Forwards drag events from the AppKit editor scroll view into the same
    /// overlay state and drop handling the group's SwiftUI `.onDrop` uses.
    /// AppKit routes a drag to the deepest registered NSView under the
    /// pointer, so without this the preview only appeared over the thin
    /// SwiftUI chrome strip (tab bar/breadcrumb) and vanished over the text.
    private var dropForwarding: EditorDropForwarding {
        EditorDropForwarding(
            updated: { location, size in
                let edge = EditorDropGeometry.target(at: location, in: size)
                isDropTargeted = true
                if edge != hoveredDropEdge {
                    withAnimation(.spring(duration: 0.22)) { hoveredDropEdge = edge }
                }
            },
            exited: {
                isDropTargeted = false
                hoveredDropEdge = nil
            },
            perform: { location, size, pasteboardPayload in
                let edge = EditorDropGeometry.target(at: location, in: size)
                isDropTargeted = false
                hoveredDropEdge = nil
                guard let payload = session.activeEditorDrag ?? pasteboardPayload else {
                    return false
                }
                session.clearEditorDrag()
                switch payload {
                case .tab(let id):
                    session.handleEditorTabDrop(id, on: group.id, edge: edge)
                case .file(let path):
                    session.handleEditorFileDrop(path: path, on: group.id, edge: edge)
                }
                return true
            }
        )
    }
}

/// Tracks the pointer during a tab or sidebar-file drag and reports the
/// nearest split edge (or `nil` for the central "open/move in place" zone)
/// so the overlay can preview the resulting pane before the drop happens.
/// Shared by every editor group and the empty-editor placeholder so tabs and
/// files get identical drop behavior.
private struct EditorDropDelegate: DropDelegate {
    let groupID: EditorGroupID
    /// `nil` for a container with no meaningful split geometry (the empty
    /// editor placeholder), which always resolves to the center zone.
    let size: CGSize?
    @Binding var hoveredEdge: EditorSplitEdge?
    @Binding var isTargeted: Bool
    let session: WorkspaceSession

    func dropEntered(info: DropInfo) {
        isTargeted = true
        hoveredEdge = edge(for: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let edge = edge(for: info.location)
        // dropEntered/dropExited pairing is unreliable when bodies re-evaluate
        // mid-drag (the delegate value is recreated); treat every update as
        // proof the drag is over this target.
        isTargeted = true
        if edge != hoveredEdge {
            withAnimation(.spring(duration: 0.22)) { hoveredEdge = edge }
        }
        // SwiftUI's macOS drag source mask can reject a `.move` proposal
        // from an `.onDrag`-originated session; `.copy` is the operation
        // that reliably validates. It's cosmetic — the underlying action is
        // always a layout move/split, never a data copy.
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        hoveredEdge = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let resolvedEdge = edge(for: info.location)
        isTargeted = false
        hoveredEdge = nil

        guard info.itemProviders(for: [.rafuEditorDrag]).first != nil else { return false }

        // Same-process fast path: the payload is already known from the
        // drag's origin, no async pasteboard round trip needed.
        if let payload = session.activeEditorDrag {
            session.clearEditorDrag()
            apply(payload, edge: resolvedEdge)
            return true
        }

        // Cross-window (or cross-process) fallback: decode the pre-encoded
        // JSON `Data` asynchronously. `action` is a `@MainActor @Sendable`
        // closure that closes over only `session` and `groupID` (not
        // `self`, which isn't `Sendable`) — safe to hand to the off-actor
        // load handler because it only ever executes after hopping back
        // onto the main actor, where touching `session` is legal even
        // though `WorkspaceSession` itself isn't `Sendable`.
        let action: @MainActor @Sendable (EditorDragPayload) -> Void = {
            [session, groupID] payload in
            session.clearEditorDrag()
            switch payload {
            case .tab(let id):
                session.handleEditorTabDrop(id, on: groupID, edge: resolvedEdge)
            case .file(let path):
                session.handleEditorFileDrop(path: path, on: groupID, edge: resolvedEdge)
            }
        }
        let providers = info.itemProviders(for: [.rafuEditorDrag])
        guard let provider = providers.first else { return false }
        _ = provider.loadDataRepresentation(for: .rafuEditorDrag) { data, _ in
            guard let data, let payload = try? EditorDragPayload(data: data) else { return }
            Task { @MainActor in
                action(payload)
            }
        }
        return true
    }

    private func edge(for location: CGPoint) -> EditorSplitEdge? {
        guard let size else { return nil }
        return EditorDropGeometry.target(at: location, in: size)
    }

    private func apply(_ payload: EditorDragPayload, edge: EditorSplitEdge?) {
        switch payload {
        case .tab(let id):
            session.handleEditorTabDrop(id, on: groupID, edge: edge)
        case .file(let path):
            session.handleEditorFileDrop(path: path, on: groupID, edge: edge)
        }
    }
}

/// Translucent preview of the pane a dragged tab would occupy — the current
/// content visually yields half the group instead of showing arrow buttons.
private struct EditorSplitPreviewOverlay: View {
    @Environment(\.rafuTheme) private var theme
    let edge: EditorSplitEdge?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: alignment) {
                theme.palette.appBackground.opacity(0.25)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.palette.accent.opacity(0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                theme.palette.accent.opacity(0.85),
                                style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                            )
                    )
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .frame(
                        width: previewSize(in: proxy.size).width,
                        height: previewSize(in: proxy.size).height
                    )
                    .padding(5)
            }
            .animation(.spring(duration: 0.22), value: edge)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var alignment: Alignment {
        switch edge {
        case .leading: .leading
        case .trailing: .trailing
        case .top: .top
        case .bottom: .bottom
        case nil: .center
        }
    }

    private func previewSize(in size: CGSize) -> CGSize {
        switch edge {
        case .leading, .trailing:
            CGSize(width: max(0, size.width / 2 - 10), height: max(0, size.height - 10))
        case .top, .bottom:
            CGSize(width: max(0, size.width - 10), height: max(0, size.height / 2 - 10))
        case nil:
            CGSize(width: max(0, size.width - 10), height: max(0, size.height - 10))
        }
    }
}

private struct WorkspaceWelcomeView: View {
    @Environment(\.rafuTheme) private var theme
    @Bindable var session: WorkspaceSession
    let openFolder: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            RafuBrandMarkView().frame(width: 96, height: 96)
            VStack(spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Rafu")
                        .font(.system(size: 40, weight: .semibold, design: .serif))
                        .kerning(-0.4)
                        .foregroundStyle(theme.palette.textPrimary)
                    Text("રફૂ").font(.system(size: 27, weight: .medium, design: .serif))
                        .foregroundStyle(theme.palette.textSecondary)
                }
                .overlay(alignment: .bottom) { DarnedUnderline().offset(y: 7) }
                Text("A native place for focused repository mending.")
                    .foregroundStyle(theme.palette.textSecondary)
            }
            Button("Open Folder…", systemImage: "folder.badge.plus", action: openFolder)
                .buttonStyle(RafuProminentButtonStyle())
                .controlSize(.large)
            HStack(alignment: .top, spacing: 16) {
                if !recents.isEmpty {
                    welcomeCard(title: "Recent Workspaces") { recentList }
                }
                welcomeCard(title: "Shortcuts") { WelcomeShortcutHints() }
            }
        }
        .padding(40)
        .task { recents = recentsStore.load() }
    }

    @State private var recents: [RecentWorkspaceEntry] = []
    private let recentsStore = RecentWorkspacesStore()

    private func welcomeCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.palette.textMuted)
                .textCase(.uppercase)
                .kerning(0.6)
            content()
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous)
                .fill(theme.palette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous)
                .strokeBorder(theme.palette.borderSubtle)
        )
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(recents.prefix(4)) { entry in
                recentRow(entry)
            }
        }
    }

    private func recentRow(_ entry: RecentWorkspaceEntry) -> some View {
        Button {
            do {
                let url = try recentsStore.resolve(entry)
                session.openLocalWorkspace(at: url)
            } catch {
                recentsStore.remove(rootPath: entry.rootPath)
                recents = recentsStore.load()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.palette.textPrimary)
                    RafuChip(
                        text: (entry.rootPath as NSString).abbreviatingWithTildeInPath,
                        foreground: theme.palette.textMuted
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous))
        }
        .buttonStyle(WelcomeRecentButtonStyle())
    }
}

private struct WelcomeRecentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        @Environment(\.rafuTheme) private var theme
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                        .fill(
                            configuration.isPressed
                                ? theme.palette.selection
                                : isHovering ? theme.palette.hover : .clear
                        )
                )
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
    }
}

private struct WelcomeShortcutHints: View {
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            hint("Go to File", keys: "⌘P")
            hint("Command Palette", keys: "⌘⇧P")
            hint("Search Workspace", keys: "⌘⇧F")
            hint("Source Control", keys: "⌘⇧G")
        }
    }

    private func hint(_ title: String, keys: String) -> some View {
        HStack(spacing: 10) {
            RafuChip(text: keys)
                .frame(width: 60, alignment: .center)
            Text(title)
                .font(.caption)
                .foregroundStyle(theme.palette.textMuted)
        }
    }
}

private struct EmptyEditorView: View {
    @Environment(\.rafuTheme) private var theme
    @State private var isDropTargeted = false
    let workspaceName: String
    @Bindable var session: WorkspaceSession

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.palette.textMuted)
            VStack(spacing: 5) {
                Text("\(workspaceName) is open")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                Text("Double-click a file in the sidebar, or press ⌘⇧P for commands.")
                    .font(.callout)
                    .foregroundStyle(theme.palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if isDropTargeted {
                EditorSplitPreviewOverlay(edge: nil)
            }
        }
        .onDrop(
            of: [.rafuEditorDrag],
            delegate: EditorDropDelegate(
                groupID: session.editorLayout.focusedGroupID,
                size: nil,
                hoveredEdge: .constant(nil),
                isTargeted: $isDropTargeted,
                session: session
            )
        )
    }
}

private struct EditorGroupTabBar: View {
    @Environment(\.rafuTheme) private var theme
    let group: EditorGroupState
    @Bindable var session: WorkspaceSession

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(group.tabs) { tab in
                        switch tab.resource {
                        case .file:
                            if let document = session.document(for: tab) {
                                EditorTabItem(
                                    tabID: tab.id,
                                    groupID: group.id,
                                    document: document,
                                    isSelected: tab.id == group.selectedTabID,
                                    session: session
                                )
                            }
                        case .terminal(let sessionID):
                            // Issue #4: same tab chrome as a file tab (icon,
                            // label, close button, selected underline) —
                            // just backed by a live terminal session instead
                            // of an `EditorDocument`.
                            if let controller = session.terminal.sessions.first(where: {
                                $0.id == sessionID
                            }) {
                                EditorTerminalTabItem(
                                    tabID: tab.id,
                                    groupID: group.id,
                                    controller: controller,
                                    isSelected: tab.id == group.selectedTabID,
                                    session: session
                                )
                            }
                        case .restorable:
                            EmptyView()
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            if let document = selectedDocument, document.supportsPresentationModes {
                Divider().frame(height: 20)
                MarkdownModeControl(
                    mode: Binding(
                        get: { document.markdownMode },
                        set: {
                            document.markdownMode = $0
                            UserDefaults.standard.set(
                                $0.rawValue, forKey: "markdownDefaultMode")
                        }
                    )
                )
                .padding(.horizontal, 6)
            }
        }
        .frame(height: RafuMetrics.tabBarHeight)
        .background(theme.palette.tabBarBackground)
        .overlay(alignment: .bottom) { Divider().overlay(theme.palette.borderSubtle) }
    }

    private var selectedDocument: EditorDocument? {
        guard let selectedTabID = group.selectedTabID,
            let tab = group.tabs.first(where: { $0.id == selectedTabID })
        else { return nil }
        return session.document(for: tab)
    }
}

/// Dashed accent line marking the active tab — Rafu's stitched seam motif.
private struct StitchedUnderline: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 2, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width - 2, y: size.height / 2))
            context.stroke(
                path, with: .color(color),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 3.5]))
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}

private struct GitStandaloneDiffCanvas: View {
    @Environment(\.rafuTheme) private var theme
    let openDiff: GitOpenDiff
    @Bindable var session: WorkspaceSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                GitDiffTabItem(
                    openDiff: openDiff,
                    isSelected: true,
                    select: session.selectGitDiff,
                    close: session.closeGitDiff
                )
                Spacer()
            }
            .frame(height: RafuMetrics.tabBarHeight)
            .background(theme.palette.tabBarBackground)
            Divider().overlay(theme.palette.borderSubtle)
            GitSideBySideDiffView(openDiff: openDiff, session: session)
        }
    }
}

private struct GitStandaloneBlameCanvas: View {
    @Environment(\.rafuTheme) private var theme
    @State private var isHoveringTab = false

    let blame: GitBlame
    let fileName: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "person.text.rectangle")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.info)
                    Text("Blame • \(fileName)")
                        .lineLimit(1)
                        .foregroundStyle(theme.palette.textPrimary)
                    Button("Close Blame", systemImage: "xmark", action: close)
                        .buttonStyle(RafuIconButtonStyle(size: 18, iconSize: 9))
                        .opacity(isHoveringTab ? 1 : 0.75)
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .frame(height: RafuMetrics.tabBarHeight)
                .overlay(alignment: .bottom) {
                    StitchedUnderline(color: theme.palette.accent)
                }
                .overlay(alignment: .trailing) {
                    Divider().frame(height: 18).overlay(theme.palette.borderSubtle)
                }
                .onHover { isHoveringTab = $0 }
                Spacer()
            }
            .frame(height: RafuMetrics.tabBarHeight)
            .background(theme.palette.tabBarBackground)
            Divider().overlay(theme.palette.borderSubtle)
            blameHeader
            Divider().overlay(theme.palette.borderSubtle)
            if blame.lines.isEmpty {
                ContentUnavailableView(
                    "No blame information",
                    systemImage: "person.text.rectangle",
                    description: Text("Git did not report any attributable lines for this file.")
                )
            } else {
                blameTable
            }
        }
        .background(theme.palette.editorBackground)
    }

    private var blameHeader: some View {
        RafuCardHeaderRow {
            HStack(spacing: 8) {
                Image(systemName: "person.text.rectangle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.info)
                RafuChip(text: fileName, foreground: theme.palette.textPrimary)
                Text("Read-only line attribution")
                    .font(.caption)
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
            }
        } trailing: {
            RafuChip(text: "\(blame.lines.count) lines", monospacedDigit: true)
        }
    }

    private var blameTable: some View {
        GeometryReader { viewport in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(blame.lines) { line in
                            GitBlameRow(line: line)
                        }
                    } header: {
                        GitBlameTableHeader()
                    }
                }
                .frame(
                    minWidth: max(780, viewport.size.width),
                    minHeight: viewport.size.height,
                    alignment: .topLeading
                )
            }
            .scrollIndicators(.visible)
        }
    }
}

private struct GitBlameTableHeader: View {
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            column("Line", width: 58, alignment: .trailing)
            column("Author", width: 170)
            column("Commit", width: 110)
            column("When", width: 130)
            column("Summary", width: nil)
        }
        .frame(height: 28)
        .background(theme.palette.tabBarBackground)
        .overlay(alignment: .bottom) { Divider().overlay(theme.palette.borderSubtle) }
    }

    private func column(
        _ title: String,
        width: CGFloat?,
        alignment: Alignment = .leading
    ) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.palette.textSecondary)
            .frame(width: width, alignment: alignment)
            .frame(
                maxWidth: width == nil ? .infinity : nil,
                maxHeight: .infinity,
                alignment: alignment
            )
            .padding(.horizontal, 8)
            .overlay(alignment: .trailing) { Divider().overlay(theme.palette.borderSubtle) }
    }
}

private struct GitBlameRow: View {
    @Environment(\.rafuTheme) private var theme
    let line: GitBlameLine

    var body: some View {
        HStack(spacing: 0) {
            cell("\(line.lineNumber)", width: 58, alignment: .trailing, monospaced: true)
            cell(line.author, width: 170)
            HStack(spacing: 4) {
                Text(line.shortID).font(.caption.monospaced())
                if line.isBoundary {
                    Text("Root")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(theme.palette.selection, in: .capsule)
                }
            }
            .frame(width: 110, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .overlay(alignment: .trailing) { Divider().overlay(theme.palette.borderSubtle) }
            Text(line.time, style: .relative)
                .font(.caption)
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 130, alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .overlay(alignment: .trailing) { Divider().overlay(theme.palette.borderSubtle) }
            cell(line.summary, width: nil)
        }
        .frame(minHeight: 30)
        .overlay(alignment: .bottom) { Divider().overlay(theme.palette.borderSubtle.opacity(0.7)) }
        .help("\(line.commitID) • \(line.summary)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private func cell(
        _ value: String,
        width: CGFloat?,
        alignment: Alignment = .leading,
        monospaced: Bool = false
    ) -> some View {
        Text(value)
            .font(monospaced ? .caption.monospacedDigit() : .caption)
            .foregroundStyle(theme.palette.textPrimary)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
            .frame(
                maxWidth: width == nil ? .infinity : nil,
                maxHeight: .infinity,
                alignment: alignment
            )
            .padding(.horizontal, 8)
            .overlay(alignment: .trailing) { Divider().overlay(theme.palette.borderSubtle) }
    }

    private var accessibilityText: String {
        let boundary = line.isBoundary ? ", root commit" : ""
        return
            "Line \(line.lineNumber), \(line.author), commit \(line.shortID)\(boundary), \(line.summary)"
    }
}

private struct GitDiffTabItem: View {
    @Environment(\.rafuTheme) private var theme
    @State private var isHovering = false

    let openDiff: GitOpenDiff
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Button(action: select) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.info)
                    Text(openDiff.title)
                        .lineLimit(1)
                        .foregroundStyle(theme.palette.textPrimary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Button("Close", systemImage: "xmark", action: close)
                .buttonStyle(RafuIconButtonStyle(size: 18, iconSize: 9))
                .opacity(isHovering || isSelected ? 1 : 0)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: RafuMetrics.tabBarHeight)
        .overlay(alignment: .bottom) {
            if isSelected { StitchedUnderline(color: theme.palette.accent) }
        }
        .overlay(alignment: .trailing) {
            Divider().frame(height: 18).overlay(theme.palette.borderSubtle)
        }
        .onHover { isHovering = $0 }
        .help(openDiff.subtitle)
    }
}

private struct GitSideBySideDiffView: View {
    @Environment(\.rafuTheme) private var theme
    let openDiff: GitOpenDiff
    @Bindable var session: WorkspaceSession

    /// Cached per-side token spans for `openDiff`, computed off-main by
    /// `DiffSyntaxHighlighter` and re-run only when `openDiff.id` changes
    /// (`.task(id:)` below) — NOT on theme change, since spans carry only a
    /// `themeKey` and `GitDiffCell` resolves the actual color at render
    /// time. `nil` before the first computation and for a diff with no
    /// eligible grammar; `GitDiffCell` renders plainly in both cases.
    @State private var highlights: DiffSyntaxHighlighter.DiffHighlights?
    /// Row → per-side line-index lookup for `highlights`, precomputed
    /// alongside it so no row-position scanning happens in `body`.
    @State private var lineIndexMap = DiffLineIndexMap(rows: [])

    var body: some View {
        VStack(spacing: 0) {
            diffHeader
            Divider().overlay(theme.palette.borderSubtle)

            if openDiff.diff.isBinary {
                ContentUnavailableView(
                    "Binary file",
                    systemImage: "doc.zipper",
                    description: Text(
                        "Rafu cannot render a textual side-by-side diff for this file.")
                )
            } else if openDiff.diff.hunks.isEmpty {
                ContentUnavailableView(
                    "No textual changes",
                    systemImage: "checkmark.circle",
                    description: Text("Git reported no line changes for this selection.")
                )
            } else {
                diffTable
            }
        }
        .background(theme.palette.editorBackground)
        .task(id: openDiff.id) {
            // Guard the assignment against a superseded task: `.task(id:)`
            // cancels but does not await the prior task, and a parse that
            // finished before cancellation would otherwise briefly overwrite
            // the NEW diff's spans with the previous diff's. The check also
            // keeps `lineIndexMap`/`highlights` mutually consistent for the
            // same diff.
            let map = DiffLineIndexMap(rows: openDiff.diff.rows)
            let result = await DiffSyntaxHighlighter.highlights(for: openDiff.diff)
            if Task.isCancelled { return }
            lineIndexMap = map
            highlights = result
        }
    }

    /// New-side-only hover entry point (Part B, product decision: the old
    /// side and non-working-tree diffs never hover). Passed to
    /// `GitSideBySideDiffRow` only when `openDiff.scope == .workingTree`
    /// (view-level gating), and `session.diffHoverInfo` re-checks the same
    /// conditions independently, so a future call site can't accidentally
    /// bypass either gate.
    private func requestHover(line: Int, utf16Column: Int) async -> EditorHoverInfo? {
        await session.diffHoverInfo(path: openDiff.diff.path, line: line, utf16Column: utf16Column)
    }

    /// Builds one diff row, indexing `highlights`/`lineIndexMap` for its
    /// spans. Extracted out of `diffTable`'s `ForEach` closure (rather than
    /// inlined) purely to keep the surrounding `ScrollView`/`LazyVStack`
    /// result-builder chain within the type checker's inference budget —
    /// no behavior difference, still a pure index into the precomputed
    /// cache, no parse work.
    private func diffRowView(for row: GitDiffRow) -> some View {
        var hoverHandler: ((Int, Int) async -> EditorHoverInfo?)?
        if openDiff.scope == .workingTree {
            hoverHandler = requestHover
        }
        return GitSideBySideDiffRow(
            row: row,
            oldSpans: highlights.flatMap { lineIndexMap.oldSpans(for: row, in: $0) },
            newSpans: highlights.flatMap { lineIndexMap.newSpans(for: row, in: $0) },
            hover: hoverHandler
        )
    }

    private var diffHeader: some View {
        RafuCardHeaderRow {
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.info)
                RafuChip(text: openDiff.title, foreground: theme.palette.textPrimary)
                Text(openDiff.subtitle)
                    .font(.caption)
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
            }
        } trailing: {
            diffStats
        }
    }

    private var diffStats: some View {
        let additions = openDiff.diff.hunks
            .flatMap(\.rows)
            .count { $0.newLine != nil && ($0.kind == .addition || $0.kind == .modification) }
        let deletions = openDiff.diff.hunks
            .flatMap(\.rows)
            .count { $0.oldLine != nil && ($0.kind == .deletion || $0.kind == .modification) }
        return HStack(spacing: 6) {
            RafuChip(
                text: "+\(additions)", foreground: theme.palette.gitAdded, monospacedDigit: true)
            RafuChip(
                text: "−\(deletions)", foreground: theme.palette.gitDeleted, monospacedDigit: true)
        }
    }

    private var diffTable: some View {
        // A both-axes ScrollView centers content smaller than the viewport;
        // stretch the table to at least the viewport size, pinned top-leading.
        GeometryReader { viewport in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(openDiff.diff.hunks) { hunk in
                            hunkHeader(hunk)
                            ForEach(hunk.rows) { row in
                                diffRowView(for: row)
                            }
                        }
                    } header: {
                        HStack(spacing: 0) {
                            diffColumnTitle("Before", symbol: "minus")
                            Divider().overlay(theme.palette.borderSubtle)
                            diffColumnTitle("After", symbol: "plus")
                        }
                        .frame(height: 28)
                        .background(theme.palette.tabBarBackground)
                    }
                }
                .frame(
                    minWidth: max(900, viewport.size.width),
                    minHeight: viewport.size.height,
                    alignment: .topLeading
                )
            }
            .scrollIndicators(.visible)
        }
    }

    private func hunkHeader(_ hunk: GitDiffHunk) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "ellipsis")
                .font(.caption2)
                .foregroundStyle(theme.palette.textMuted)
            Text(hunk.header)
                .font(.caption.monospaced())
                .foregroundStyle(theme.palette.accent)
            Spacer(minLength: 12)
            if let action = hunkAction {
                Button(action.title, systemImage: action.systemImage) {
                    perform(action, on: hunk)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(session.isGitBusy || session.isGitHunkActionBusy)
                .help(action.help)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .padding(.horizontal, 12)
        .background(theme.palette.selection.opacity(0.45))
        .overlay(alignment: .top) { Divider().overlay(theme.palette.borderSubtle) }
        .overlay(alignment: .bottom) { Divider().overlay(theme.palette.borderSubtle) }
        .contextMenu {
            if let action = hunkAction {
                Button(action.title, systemImage: action.systemImage) {
                    perform(action, on: hunk)
                }
                .disabled(session.isGitBusy || session.isGitHunkActionBusy)
            }
        }
    }

    private var hunkAction: HunkAction? {
        guard
            session.gitSnapshot?.changes.first(where: { $0.path == openDiff.diff.path })?.kind
                == .modified
        else { return nil }
        switch openDiff.scope {
        case .workingTree: return .stage
        case .staged: return .unstage
        case .commit, .between: return nil
        }
    }

    private func perform(_ action: HunkAction, on hunk: GitDiffHunk) {
        Task {
            switch action {
            case .stage: await session.stageHunk(hunk)
            case .unstage: await session.unstageHunk(hunk)
            }
        }
    }

    private enum HunkAction: Equatable {
        case stage
        case unstage

        var title: String { self == .stage ? "Stage Hunk" : "Unstage Hunk" }
        var systemImage: String { self == .stage ? "plus.circle" : "minus.circle" }
        var help: String {
            self == .stage
                ? "Stage only this hunk in the Git index"
                : "Remove only this hunk from the Git index"
        }
    }

    private func diffColumnTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
    }
}

private struct GitSideBySideDiffRow: View {
    @Environment(\.rafuTheme) private var theme
    let row: GitDiffRow
    var oldSpans: [SyntaxSpan]?
    var newSpans: [SyntaxSpan]?
    /// New-side-only hover request, `nil` for a history/commit-scoped diff
    /// (`GitSideBySideDiffView` never passes one). Threaded straight through
    /// to the new-side `GitDiffCell`; the old-side cell never receives it,
    /// so it structurally cannot hover.
    var hover: ((Int, Int) async -> EditorHoverInfo?)?

    var body: some View {
        let spans =
            row.kind == .modification
            ? IntralineDiff.changedSpans(
                old: row.oldLine?.content ?? "",
                new: row.newLine?.content ?? ""
            )
            : nil
        HStack(spacing: 0) {
            GitDiffCell(
                line: row.oldLine, side: .old, rowKind: row.kind,
                changedSpan: spans?.old, syntaxSpans: oldSpans
            )
            Divider().overlay(theme.palette.borderSubtle.opacity(0.6))
            GitDiffCell(
                line: row.newLine, side: .new, rowKind: row.kind,
                changedSpan: spans?.new, syntaxSpans: newSpans, hover: hover
            )
        }
        .frame(minHeight: 21)
    }
}

private struct GitDiffCell: View {
    enum Side { case old, new }

    @Environment(\.rafuTheme) private var theme
    let line: GitDiffLine?
    let side: Side
    let rowKind: GitDiffRowKind
    var changedSpan: Range<Int>?
    /// Precomputed token spans for this line (UTF-16, line-relative), or
    /// `nil` for plain rendering — no grammar, an unopened diff cache, or a
    /// side over `DiffSyntaxHighlighter`'s highlighted-length cap. No parse
    /// work happens here; this view only indexes into the cache.
    var syntaxSpans: [SyntaxSpan]?
    /// New-side-only hover request (`(line, utf16Column) async ->
    /// EditorHoverInfo?`). `nil` for the old-side cell always, and for the
    /// new-side cell of a history/commit-scoped diff — the product decision
    /// that only the new side of a working-tree diff ever hovers.
    var hover: ((Int, Int) async -> EditorHoverInfo?)?

    @State private var hoverDebounceTask: Task<Void, Never>?
    @State private var hoverInfo: EditorHoverInfo?
    @State private var isHoverPresented = false

    /// UTF-16-column advance for `.system(size: 12, design: .monospaced)` —
    /// the diff cell's fixed content font — computed once via `NSFont`
    /// metrics rather than per hover event. Pragmatic v1 column estimation
    /// (phase brief B3): `column ≈ pointerX / monospaceAdvance`, clamped to
    /// the line's UTF-16 length. Emoji/wide-glyph drift is accepted —
    /// `IdentifierUnderCaret` snaps to the nearest word, and a miss shows no
    /// card rather than a wrong one.
    private static let monospaceAdvance: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }()

    /// Debounce before a stable hover resolves — matches the editor's own
    /// hover delay (`RafuTextView.hoverDelay`) so both surfaces feel
    /// consistent.
    private static let hoverDelay: Duration = .milliseconds(350)

    var body: some View {
        HStack(spacing: 0) {
            Text(line.map { String($0.number) } ?? "")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(gutterColor)
                .frame(width: 42, alignment: .trailing)
                .padding(.trailing, 6)
                .frame(maxHeight: .infinity)
                .background(gutterBackground)
            Text(marker)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(markerColor)
                .frame(width: 16)
            Text(attributedContent)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let point):
                        scheduleHover(at: point.x)
                    case .ended:
                        cancelHover()
                    }
                }
                .popover(isPresented: $isHoverPresented, arrowEdge: .bottom) {
                    if let hoverInfo {
                        EditorHoverTooltipView(info: hoverInfo, theme: theme)
                    }
                }
        }
        .frame(maxWidth: .infinity, minHeight: 21, alignment: .leading)
        .background(backgroundColor)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .onDisappear(perform: cancelHover)
    }

    /// Schedules a debounced hover resolve at pointer x-offset `x` within
    /// the content `Text`'s local coordinate space. A no-op for the old
    /// side, a row without a `newLine`, a diff with no `hover` handler
    /// (history/commit scope), or a column with no identifier under it —
    /// every one of those cases must never show a card (AGENTS: state is
    /// never color-only, and old-side/history hover is an explicit
    /// non-goal). Cancels any in-flight resolve first so a fast pointer
    /// sweep never stacks requests or shows a stale card.
    private func scheduleHover(at x: CGFloat) {
        hoverDebounceTask?.cancel()
        guard side == .new, let line, let hover else {
            cancelHover()
            return
        }
        let column = Self.column(forX: x, in: line.content)
        guard IdentifierUnderCaret.word(in: line.content, at: column) != nil else {
            cancelHover()
            return
        }
        let requestedLine = line.number
        hoverDebounceTask = Task {
            try? await Task.sleep(for: Self.hoverDelay)
            if Task.isCancelled { return }
            let info = await hover(requestedLine, column)
            if Task.isCancelled { return }
            hoverInfo = info
            isHoverPresented = info != nil
        }
    }

    /// Cancels any in-flight/scheduled resolve and dismisses the card —
    /// pointer exit, row teardown, and a declined hover attempt all funnel
    /// through here so hover never lingers or blocks scrolling (AGENTS).
    private func cancelHover() {
        hoverDebounceTask?.cancel()
        hoverDebounceTask = nil
        isHoverPresented = false
    }

    private static func column(forX x: CGFloat, in content: String) -> Int {
        let length = (content as NSString).length
        guard monospaceAdvance > 0 else { return 0 }
        let raw = Int((x / monospaceAdvance).rounded())
        return max(0, min(raw, length))
    }

    private var attributedContent: AttributedString {
        guard let line else { return AttributedString("") }
        var text = AttributedString(line.content)
        text.foregroundColor = theme.palette.textPrimary

        if let syntaxSpans {
            let contentLength = (line.content as NSString).length
            for span in syntaxSpans {
                guard span.range.location >= 0, span.range.length > 0,
                    span.range.location + span.range.length <= contentLength,
                    let hex = theme.syntax[span.themeKey]?.color,
                    let range = Range<AttributedString.Index>(span.range, in: text)
                else { continue }
                text[range].foregroundColor = Color(rafuHex: hex)
            }
        }

        if let changedSpan, isChanged, !changedSpan.isEmpty,
            changedSpan.upperBound <= line.content.count
        {
            let start = text.index(text.startIndex, offsetByCharacters: changedSpan.lowerBound)
            let end = text.index(text.startIndex, offsetByCharacters: changedSpan.upperBound)
            text[start..<end].backgroundColor =
                side == .old
                ? theme.palette.diffRemovedWordBackground
                : theme.palette.diffAddedWordBackground
        }
        return text
    }

    private var isChanged: Bool {
        side == .old
            ? rowKind == .deletion || rowKind == .modification
            : rowKind == .addition || rowKind == .modification
    }

    private var marker: String {
        guard line != nil, isChanged else { return "" }
        return side == .old ? "−" : "+"
    }

    private var markerColor: Color {
        side == .old ? theme.palette.diffRemovedGutter : theme.palette.diffAddedGutter
    }

    private var gutterColor: Color {
        guard line != nil else { return theme.palette.gutterForeground.opacity(0.4) }
        return isChanged ? markerColor : theme.palette.gutterForeground
    }

    private var gutterBackground: Color {
        guard line != nil, isChanged else { return .clear }
        return
            (side == .old
            ? theme.palette.diffRemovedBackground
            : theme.palette.diffAddedBackground)
            .opacity(0.8)
    }

    private var backgroundColor: Color {
        guard line != nil else {
            return theme.palette.appBackground.opacity(0.35)
        }
        guard isChanged else { return .clear }
        return side == .old
            ? theme.palette.diffRemovedBackground
            : theme.palette.diffAddedBackground
    }

    private var accessibilityText: String {
        guard let line else { return "No corresponding line" }
        let change = marker == "+" ? "Added" : marker == "−" ? "Removed" : "Context"
        return "\(change), line \(line.number): \(line.content)"
    }
}

private struct EditorTabItem: View {
    @Environment(\.rafuTheme) private var theme
    @State private var isHovering = false

    let tabID: EditorTabID
    let groupID: EditorGroupID
    let document: EditorDocument
    let isSelected: Bool
    @Bindable var session: WorkspaceSession

    var body: some View {
        let icon = FileIconProvider.fileIcon(named: document.displayName)
        HStack(spacing: 7) {
            Button {
                session.selectEditorTab(tabID, in: groupID)
            } label: {
                HStack(spacing: 7) {
                    FileIconView(icon: icon, size: 11)
                    Text(document.displayName)
                        .lineLimit(1)
                        .foregroundStyle(
                            isSelected
                                ? theme.palette.textPrimary
                                : theme.palette.textSecondary
                        )
                    if document.isDirty {
                        Circle().fill(theme.palette.accent).frame(width: 6, height: 6)
                            .accessibilityLabel("Unsaved changes")
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Button("Close", systemImage: "xmark") { session.requestClose(document) }
                .buttonStyle(RafuIconButtonStyle(size: 18, iconSize: 9))
                .opacity(isHovering || isSelected ? 1 : 0)
                .help("Close \(document.displayName)")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: RafuMetrics.tabBarHeight)
        .background {
            if isHovering {
                theme.palette.hover.opacity(0.6)
            } else {
                Color.clear
            }
        }
        .overlay(alignment: .bottom) {
            if isSelected { StitchedUnderline(color: theme.palette.accent) }
        }
        .overlay(alignment: .trailing) {
            Divider().frame(height: 18).overlay(theme.palette.borderSubtle)
        }
        .onHover { isHovering = $0 }
        .onDrag { session.beginEditorDrag(.tab(id: tabID.rawValue.uuidString)) }
        .contextMenu {
            Button("Split Left", systemImage: "rectangle.split.2x1") {
                session.splitEditorTab(tabID, at: .leading)
            }
            Button("Split Right", systemImage: "rectangle.split.2x1") {
                session.splitEditorTab(tabID, at: .trailing)
            }
            Button("Split Up", systemImage: "rectangle.split.1x2") {
                session.splitEditorTab(tabID, at: .top)
            }
            Button("Split Down", systemImage: "rectangle.split.1x2") {
                session.splitEditorTab(tabID, at: .bottom)
            }
            Divider()
            Button("Close") { session.requestClose(document) }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Issue #4: a terminal tab, presented with the EXACT SAME chrome as
/// `EditorTabItem` (icon, label, close button, hover, selected underline,
/// trailing divider, drag/split context menu) — just backed by a live
/// `WorkspaceTerminalController` instead of an `EditorDocument`. This tab's
/// own ✕/context-menu "Close" always terminates the shell
/// (`session.closeTerminalTab`); there is no dirty-state confirmation, since
/// a terminal has no unsaved buffer. Hiding without killing the shell is a
/// separate verb (⌃`/`toggleTerminal` → `session.hideTerminalTab`), not
/// reachable from this tab item — see terminal-manager.md T-A.
private struct EditorTerminalTabItem: View {
    @Environment(\.rafuTheme) private var theme
    @State private var isHovering = false

    let tabID: EditorTabID
    let groupID: EditorGroupID
    @Bindable var controller: WorkspaceTerminalController
    let isSelected: Bool
    @Bindable var session: WorkspaceSession

    var body: some View {
        HStack(spacing: 7) {
            Button {
                session.selectEditorTab(tabID, in: groupID)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.palette.accent)
                    Text(TerminalSessionPresentation.tabLabel(controller.displayName))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(
                            isSelected
                                ? theme.palette.textPrimary
                                : theme.palette.textSecondary
                        )
                    // Never communicated by color alone: the running/stopped
                    // dot pairs with the "Shell exited" content overlay text.
                    // `.bell` is not exited (terminal-manager.md T-E
                    // regression guard — see `EditorTerminalTabContent`'s
                    // identical note), so this uses the same separately
                    // tested `isExited` predicate rather than `!isRunning`.
                    if TerminalSessionPresentation.isExited(controller.status) {
                        Circle().fill(theme.palette.textMuted).frame(width: 6, height: 6)
                            .accessibilityLabel("Shell exited")
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Button("Close", systemImage: "xmark") { session.closeTerminalTab(tabID) }
                .buttonStyle(RafuIconButtonStyle(size: 18, iconSize: 9))
                .opacity(isHovering || isSelected ? 1 : 0)
                .help("Close \(controller.displayName)")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: RafuMetrics.tabBarHeight)
        .background {
            if isHovering {
                theme.palette.hover.opacity(0.6)
            } else {
                Color.clear
            }
        }
        .overlay(alignment: .bottom) {
            if isSelected { StitchedUnderline(color: theme.palette.accent) }
        }
        .overlay(alignment: .trailing) {
            Divider().frame(height: 18).overlay(theme.palette.borderSubtle)
        }
        .overlay(alignment: .leading) {
            // Color TAG (terminal-manager.md T-D) — correlates this tab
            // with its panel row's dot. Never the only signal: paired with
            // the label/icon/dot text as always.
            if let sessionColor = controller.sessionColor {
                Rectangle()
                    .fill(theme.palette.color(for: sessionColor))
                    .frame(width: 2)
                    .accessibilityHidden(true)
            }
        }
        .onHover { isHovering = $0 }
        .onDrag { session.beginEditorDrag(.tab(id: tabID.rawValue.uuidString)) }
        .contextMenu {
            Button("Split Left", systemImage: "rectangle.split.2x1") {
                session.splitEditorTab(tabID, at: .leading)
            }
            Button("Split Right", systemImage: "rectangle.split.2x1") {
                session.splitEditorTab(tabID, at: .trailing)
            }
            Button("Split Up", systemImage: "rectangle.split.1x2") {
                session.splitEditorTab(tabID, at: .top)
            }
            Button("Split Down", systemImage: "rectangle.split.1x2") {
                session.splitEditorTab(tabID, at: .bottom)
            }
            Divider()
            Button("Restart Shell", systemImage: "arrow.clockwise") { controller.restart() }
            Divider()
            Button("Close") { session.closeTerminalTab(tabID) }
        }
        .accessibilityElement(children: .contain)
        .help(controller.currentDirectoryPath ?? controller.startingDirectory)
    }
}

private struct EditorDocumentView: View {
    @Environment(\.rafuTheme) private var theme
    @Bindable var document: EditorDocument
    let findState: DocumentFindState
    let gitLineChangesProvider: (@MainActor () async -> GitGutterLineChanges?)?
    var requestGitRefresh: (@MainActor () -> Void)? = nil
    var dropForwarding: EditorDropForwarding? = nil
    var navigate: (@MainActor (NavigationTargetKind) -> Void)? = nil
    var hover: (@MainActor (Int) async -> EditorHoverInfo?)? = nil
    var inlineBlameEnabled: Bool = false
    var inlineBlameProvider: (@MainActor () async -> GitBlame?)? = nil
    var fileBlameAnnotationsEnabled: Bool = false
    var fileBlameAnnotationsProvider: (@MainActor () async -> GitBlame?)? = nil
    var aiCompletionEnabled: Bool = false
    var aiCompletionProvider: (@MainActor (String, String) async -> String?)? = nil
    var gitPeekActions: GitPeekActions? = nil

    var body: some View {
        VStack(spacing: 0) {
            if document.suppressesSyntax {
                GuardBannerView(document: document)
            }
            Group {
                if document.isBitmapImage {
                    ImagePreviewView(url: document.url)
                } else if document.isMarkdown || document.isSVG {
                    MarkdownEditorPresentation(
                        document: document,
                        findState: findState,
                        theme: theme,
                        gitLineChangesProvider: gitLineChangesProvider,
                        requestGitRefresh: requestGitRefresh,
                        dropForwarding: dropForwarding,
                        navigate: navigate,
                        hover: hover,
                        inlineBlameEnabled: inlineBlameEnabled,
                        inlineBlameProvider: inlineBlameProvider,
                        fileBlameAnnotationsEnabled: fileBlameAnnotationsEnabled,
                        fileBlameAnnotationsProvider: fileBlameAnnotationsProvider,
                        aiCompletionEnabled: aiCompletionEnabled,
                        aiCompletionProvider: aiCompletionProvider,
                        gitPeekActions: gitPeekActions
                    )
                } else {
                    CodeEditorView(
                        document: document,
                        theme: theme,
                        findState: findState,
                        gitLineChangesProvider: gitLineChangesProvider,
                        requestGitRefresh: requestGitRefresh,
                        dropForwarding: dropForwarding,
                        navigate: navigate,
                        hover: hover,
                        inlineBlameEnabled: inlineBlameEnabled,
                        inlineBlameProvider: inlineBlameProvider,
                        fileBlameAnnotationsEnabled: fileBlameAnnotationsEnabled,
                        fileBlameAnnotationsProvider: fileBlameAnnotationsProvider,
                        aiCompletionEnabled: aiCompletionEnabled,
                        aiCompletionProvider: aiCompletionProvider,
                        gitPeekActions: gitPeekActions
                    )
                }
            }
        }
        .alert("Editor Error", isPresented: errorBinding) {
            Button("OK", role: .cancel) { document.errorMessage = nil }
        } message: {
            Text(document.errorMessage ?? "The editor encountered an error.")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { document.errorMessage != nil },
            set: { if !$0 { document.errorMessage = nil } }
        )
    }
}

/// Shown above a guarded document's editor: explains why highlighting and
/// symbols are off (via icon and text, never color alone) and offers a
/// one-click override for the rest of this session.
///
/// Deferred: dedicated menu/palette override command; the banner button is
/// this increment's sole override path.
private struct GuardBannerView: View {
    @Environment(\.rafuTheme) private var theme
    let document: EditorDocument

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.palette.warning)
                .padding(5)
                .background(Circle().fill(theme.palette.chipBackground))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Enable Highlighting") { document.overrideGuard() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.tabBarBackground)
        .overlay(alignment: .bottom) { Divider().overlay(theme.palette.borderSubtle) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message) Enable Highlighting")
    }

    private var message: String {
        guard case .guarded(let reason) = document.guardState else {
            return "Highlighting and symbols are off for this large file."
        }
        switch reason {
        case .tooLarge:
            return "Highlighting and symbols are off for this large file."
        case .longLine:
            return "Highlighting and symbols are off because this file has a very long line."
        }
    }
}

private struct MarkdownEditorPresentation: View {
    @Bindable var document: EditorDocument
    let findState: DocumentFindState
    let theme: RafuTheme
    let gitLineChangesProvider: (@MainActor () async -> GitGutterLineChanges?)?
    var requestGitRefresh: (@MainActor () -> Void)? = nil
    var dropForwarding: EditorDropForwarding? = nil
    var navigate: (@MainActor (NavigationTargetKind) -> Void)? = nil
    var hover: (@MainActor (Int) async -> EditorHoverInfo?)? = nil
    var inlineBlameEnabled: Bool = false
    var inlineBlameProvider: (@MainActor () async -> GitBlame?)? = nil
    var fileBlameAnnotationsEnabled: Bool = false
    var fileBlameAnnotationsProvider: (@MainActor () async -> GitBlame?)? = nil
    var aiCompletionEnabled: Bool = false
    var aiCompletionProvider: (@MainActor (String, String) async -> String?)? = nil
    var gitPeekActions: GitPeekActions? = nil

    var body: some View {
        switch document.markdownMode {
        case .edit:
            editor
        case .preview:
            renderedPreview
        case .split:
            HSplitView {
                editor.frame(minWidth: 220)
                renderedPreview
                    .frame(minWidth: 220)
            }
        }
    }

    private var editor: some View {
        CodeEditorView(
            document: document,
            theme: theme,
            findState: findState,
            gitLineChangesProvider: gitLineChangesProvider,
            requestGitRefresh: requestGitRefresh,
            dropForwarding: dropForwarding,
            navigate: navigate,
            hover: hover,
            inlineBlameEnabled: inlineBlameEnabled,
            inlineBlameProvider: inlineBlameProvider,
            fileBlameAnnotationsEnabled: fileBlameAnnotationsEnabled,
            fileBlameAnnotationsProvider: fileBlameAnnotationsProvider,
            aiCompletionEnabled: aiCompletionEnabled,
            aiCompletionProvider: aiCompletionProvider,
            gitPeekActions: gitPeekActions
        )
    }

    @ViewBuilder
    private var renderedPreview: some View {
        if document.isSVG {
            ImagePreviewView(url: document.url)
                .id(document.id)
        } else {
            MarkdownPreviewView(document: document)
                .id(document.id)
        }
    }
}

private struct DocumentFindBar: View {
    @Environment(\.rafuTheme) private var theme
    @Bindable var state: DocumentFindState
    @Binding var showsReplace: Bool
    let close: () -> Void

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case query
        case replacement
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                TextField("Find", text: $state.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .query)
                    .onSubmit { state.findNext() }
                Text(matchSummary).font(.caption.monospacedDigit())
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(minWidth: 48)
                Button("Previous Match", systemImage: "chevron.up") { state.findPrevious() }
                    .buttonStyle(RafuIconButtonStyle(size: 22))
                    .help("Previous Match")
                Button("Next Match", systemImage: "chevron.down") { state.findNext() }
                    .buttonStyle(RafuIconButtonStyle(size: 22))
                    .help("Next Match")
                findOptionButton("Case Sensitive", symbol: "textformat", option: .caseSensitive)
                findOptionButton("Whole Word", symbol: "character.cursor.ibeam", option: .wholeWord)
                findOptionButton(
                    "Regular Expression", symbol: "asterisk", option: .regularExpression)
                Button(
                    showsReplace ? "Hide Replace" : "Show Replace",
                    systemImage: showsReplace ? "chevron.down" : "chevron.right"
                ) { showsReplace.toggle() }
                .buttonStyle(RafuIconButtonStyle(isActive: showsReplace, size: 22))
                .help(showsReplace ? "Hide Replace" : "Show Replace")
                Button("Close Find", systemImage: "xmark", action: close)
                    .buttonStyle(RafuIconButtonStyle(size: 22))
                    .help("Close Find")
            }
            if showsReplace {
                HStack(spacing: 6) {
                    TextField("Replace", text: $state.replacement)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .replacement)
                        .onSubmit { state.replaceCurrent() }
                    Button("Replace") { state.replaceCurrent() }
                        .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    Button("Replace All") { state.replaceAll() }
                        .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                }
            }
            if let errorMessage = state.errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(theme.palette.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(theme.palette.elevatedBackground.opacity(0.65))
        .defaultFocus($focusedField, .query)
    }

    private var matchSummary: String {
        guard state.matchCount > 0 else { return "No results" }
        return "\((state.currentMatchIndex ?? 0) + 1) of \(state.matchCount)"
    }

    private func findOptionButton(
        _ title: String,
        symbol: String,
        option: TextSearchOptions
    ) -> some View {
        let selected = state.options.contains(option)
        return Button(title, systemImage: symbol) {
            if selected {
                state.options.remove(option)
            } else {
                state.options.insert(option)
            }
        }
        .buttonStyle(RafuIconButtonStyle(isActive: selected, size: 22))
        .help(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct MarkdownModeControl: View {
    @Environment(\.rafuTheme) private var theme
    @Binding var mode: MarkdownPresentationMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MarkdownPresentationMode.allCases, id: \.rawValue) { item in
                modeButton(item)
            }
        }
        .padding(2)
        .background(theme.palette.appBackground.opacity(0.55), in: .rect(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(theme.palette.borderSubtle)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Markdown presentation")
    }

    private func modeButton(_ item: MarkdownPresentationMode) -> some View {
        Button(item.title, systemImage: item.symbolName) {
            withAnimation(.spring(duration: 0.22)) { mode = item }
        }
        .buttonStyle(
            RafuIconButtonStyle(isActive: item == mode, size: 24, iconSize: 11)
        )
        .help(item.title)
        .accessibilityAddTraits(item == mode ? .isSelected : [])
    }
}

struct RafuBrandMarkView: View {
    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().scaledToFit().accessibilityLabel("Rafu seam mark")
        } else {
            Image(systemName: "scribble.variable").resizable().scaledToFit().foregroundStyle(
                .secondary
            )
            .accessibilityLabel("Rafu seam mark")
        }
    }

    private static let image: NSImage? = {
        let candidates = [
            Bundle.main.url(
                forResource: "rafu-icon-seam", withExtension: "svg", subdirectory: "AppIcon"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(
                path: "Resources/AppIcon/rafu-icon-seam.svg"),
        ]
        return candidates.compactMap { $0 }.compactMap(NSImage.init(contentsOf:)).first
    }()
}

private struct DarnedUnderline: View {
    @Environment(\.rafuTheme) private var theme
    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addCurve(
                to: CGPoint(x: size.width, y: size.height / 2),
                control1: CGPoint(x: size.width * 0.3, y: 0),
                control2: CGPoint(x: size.width * 0.65, y: size.height)
            )
            context.stroke(
                path, with: .color(theme.palette.accent),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [7, 4]))
        }
        .frame(height: 8).accessibilityHidden(true)
    }
}
