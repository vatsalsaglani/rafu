import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EditorCanvasView: View {
    @Environment(\.rafuTheme) private var theme
    @Bindable var session: WorkspaceSession
    let openFolder: () -> Void

    var body: some View {
        ZStack {
            canvas(for: layoutRoute)
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

    private var layoutRoute: EditorCanvasRoute {
        let route = EditorCanvasRoute.resolve(.init(session: session))
        // Keep the same layout-tree identity while an auxiliary tab is open.
        // Only the owning group's content changes; every split stays visible.
        switch route {
        case .settings:
            return .editor
        case .welcome, .empty:
            return session.auxiliaryTabs.isEmpty ? route : .editor
        default:
            return route
        }
    }

    /// One branch per canvas mode. Which mode is current is decided by
    /// `EditorCanvasRoute.resolve`, never here — the `if let` unwraps below
    /// only re-obtain values the route has already proven present.
    @ViewBuilder
    private func canvas(for route: EditorCanvasRoute) -> some View {
        switch route {
        case .welcome:
            WorkspaceWelcomeView(session: session, openFolder: openFolder)
        case .empty:
            EmptyEditorView(
                workspaceName: session.descriptor?.displayName ?? "Workspace",
                session: session
            )
        case .blame:
            if let blame = session.gitOpenBlame, let document = session.selectedDocument {
                GitStandaloneBlameCanvas(
                    blame: blame,
                    fileName: document.displayName,
                    close: session.closeBlame
                )
            }
        case .standaloneDiff:
            if let openDiff = session.gitOpenDiff {
                GitStandaloneDiffCanvas(openDiff: openDiff, session: session)
            }
        case .settings:
            SettingsCanvas(session: session)
        case .editor:
            EditorLayoutTreeView(node: session.editorLayout.root, session: session)
        }
    }

    private var closeAlertBinding: Binding<Bool> {
        Binding(
            get: { session.pendingCloseDocument != nil },
            set: { if !$0 { session.pendingCloseDocument = nil } }
        )
    }
}

nonisolated enum EditorGroupSplitPresentation {
    /// `HSplitView`/`VSplitView` already contribute their native divider to
    /// the visible band between leaves. Add only the remainder on the first
    /// leaf so the complete edge-to-edge band stays at the semantic target.
    static func compensatingInset(nativeDividerWidth: CGFloat) -> CGFloat {
        max(0, RafuMetrics.editorGroupGapTarget - nativeDividerWidth)
    }
}

private struct EditorTerminalIdentityPresentation {
    let color: Color
    let matchesEditorBackground: Bool
}

private struct EditorLayoutTreeView: View {
    @Environment(\.rafuTheme) private var theme

    let node: EditorLayoutNode
    @Bindable var session: WorkspaceSession

    var body: some View {
        renderedNode
            .background(theme.palette.appBackground)
    }

    private var renderedNode: AnyView {
        let compensatingInset = EditorGroupSplitPresentation.compensatingInset(
            nativeDividerWidth: RafuMetrics.hairline
        )
        switch node {
        case .group(let group):
            return AnyView(EditorGroupView(group: group, session: session))
        case .split(_, let axis, _, let first, let second):
            switch axis {
            case .horizontal:
                return AnyView(
                    HSplitView {
                        EditorLayoutTreeView(node: first, session: session)
                            .frame(minWidth: 220)
                            .padding(.trailing, compensatingInset)
                        EditorLayoutTreeView(node: second, session: session).frame(minWidth: 220)
                    }
                    .background(theme.palette.appBackground)
                )
            case .vertical:
                return AnyView(
                    VSplitView {
                        EditorLayoutTreeView(node: first, session: session)
                            .frame(minHeight: 150)
                            .padding(.bottom, compensatingInset)
                        EditorLayoutTreeView(node: second, session: session).frame(minHeight: 150)
                    }
                    .background(theme.palette.appBackground)
                )
            }
        }
    }
}

private struct EditorGroupView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rafuTheme) private var theme
    @State private var hoveredDropEdge: EditorSplitEdge?
    @State private var isDropTargeted = false

    let group: EditorGroupState
    @Bindable var session: WorkspaceSession

    var body: some View {
        // Editor callbacks capture this value, not the view and its session.
        let group = group
        let terminalIdentities = terminalIdentityPresentations
        let selectedTerminalIdentity = selectedTerminalController.flatMap {
            terminalIdentities[$0.id]
        }

        return EditorGroupSurface(
            isFocused: session.isFocusedGroup(group.id),
            terminalIdentityColor: selectedTerminalIdentity?.color,
            identityMatchesEditorBackground:
                selectedTerminalIdentity?.matchesEditorBackground == true,
            hostsTerminal: selectedTerminalController != nil || selectedTerminalGroupID != nil,
            hasSiblings: session.editorLayout.groupIDs.count > 1
        ) {
            VStack(spacing: 0) {
                // The tab strip owns its own drop target
                // (`TabStripReorderDropDelegate`, wired up inside
                // `EditorGroupTabBar` below), and the group's own split/move
                // `.onDrop` — attached further down, only to the body BELOW
                // this tab bar — deliberately excludes the tab bar's frame.
                EditorGroupTabBar(
                    group: group,
                    terminalIdentities: terminalIdentities,
                    session: session
                )
                GeometryReader { proxy in
                    VStack(spacing: 0) {
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
                            // The shared group surface owns the only complete
                            // perimeter. This body-only host remains unmasked
                            // and keeps its live SwiftTerm view and responder
                            // identity across tab moves and remounts.
                            EditorTerminalTabContent(controller: terminalController)
                        } else if let terminalGroupID = selectedTerminalGroupID,
                            let snapshot = session.terminal.terminalGroup(terminalGroupID)
                        {
                            if session.canvasTerminalOwners[terminalGroupID] != nil {
                                ContentUnavailableView {
                                    Label(
                                        "Terminal is in an Ensemble",
                                        systemImage: "rectangle.3.group")
                                } description: {
                                    Text("Transfer its existing view to this tab to continue here.")
                                } actions: {
                                    Button("Transfer Here") {
                                        session.canvasTerminalOwners[terminalGroupID] = nil
                                    }
                                }
                            } else {
                                TerminalGroupView(
                                    snapshot: snapshot,
                                    controllerForPane: {
                                        session.terminal.terminalController(for: $0)
                                    },
                                    action: session.performTerminalGroupViewAction,
                                    theme: theme,
                                    requestFocusToken: session.terminalGroupFocusRequest
                                )
                                .environment(
                                    \.terminalSurfaceCanMount,
                                    { [weak session = session] in
                                        session?.canvasTerminalOwners[terminalGroupID] == nil
                                    })
                            }
                        } else if loadedDocuments.isEmpty {
                            ContentUnavailableView(
                                "Empty Editor Group",
                                systemImage: "rectangle.split.2x1",
                                description: Text(
                                    "Drag a tab here or open a file from the sidebar.")
                            )
                        } else {
                            // The bounded working set: every LOADED document in
                            // this group stays mounted so TextKit keeps owning
                            // its live text. Only the selected editor is visible
                            // and interactive; inactive documents stay mounted.
                            ZStack {
                                ForEach(loadedDocuments) { document in
                                    let isActive =
                                        document.id == selectedDocument?.id
                                        && session.selectedAuxiliaryTab(in: group.id) == nil
                                        && selectedCanvas == nil
                                    EditorDocumentView(
                                        document: document,
                                        isVisible: isActive,
                                        findState: session.findState(for: document),
                                        requestFind: {
                                            [weak session = session, weak document = document] in
                                            guard let session, let document,
                                                let tab = group.tabs.first(where: {
                                                    $0.resource == .file(document.url)
                                                })
                                            else { return }
                                            session.selectEditorTab(tab.id, in: group.id)
                                            session.showDocumentFind()
                                        },
                                        gitLineChangesProvider: {
                                            [weak session = session, weak document = document] in
                                            guard let session, let document else { return nil }
                                            return await session.gutterLineChanges(for: document)
                                        },
                                        requestGitRefresh: { [weak session = session] in
                                            guard let session else { return }
                                            Task { await session.refreshGit() }
                                        },
                                        dropForwarding: isActive ? dropForwarding : nil,
                                        navigate: { [weak session = session] kind in
                                            session?.navigate(kind: kind)
                                        },
                                        hover: {
                                            [weak session = session, weak document = document]
                                            offset in
                                            guard let session, let document else { return nil }
                                            return await session.hoverInfo(
                                                at: document.url, utf16Offset: offset)
                                        },
                                        inlineBlameEnabled: session.isInlineBlameEnabled,
                                        inlineBlameProvider: {
                                            [weak session = session, weak document = document] in
                                            guard let session, let document else { return nil }
                                            return await session.inlineBlame(for: document)
                                        },
                                        fileBlameAnnotationsEnabled: session
                                            .isFileBlameAnnotationsEnabled,
                                        fileBlameAnnotationsProvider: {
                                            [weak session = session, weak document = document] in
                                            guard let session, let document else { return nil }
                                            return await session.fileBlameAnnotations(for: document)
                                        },
                                        aiCompletionEnabled: session.isAICompletionEnabled,
                                        aiCompletionProvider: {
                                            [weak session = session, weak document = document]
                                            prefix, suffix in
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
                    // Overlays receive the base view's size. An empty editor
                    // has only its placeholder's intrinsic size, so claim the
                    // complete group body before presenting Canvas or Settings.
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                    .opacity(
                        session.selectedAuxiliaryTab(in: group.id) == nil && selectedCanvas == nil
                            ? 1 : 0
                    )
                    .allowsHitTesting(
                        session.selectedAuxiliaryTab(in: group.id) == nil && selectedCanvas == nil
                    )
                    .accessibilityHidden(
                        session.selectedAuxiliaryTab(in: group.id) != nil || selectedCanvas != nil
                    )
                    .overlay {
                        if let board = selectedCanvas {
                            WorkspaceCanvasView(board: board, session: session)
                                .id(board.id)
                        }
                    }
                    .overlay {
                        ForEach(session.auxiliaryTabs(in: group.id)) { tab in
                            AuxiliaryEditorFocusHost(
                                isActive: session.selectedAuxiliaryTab(in: group.id) == tab
                            ) {
                                AuxiliaryEditorTabContent(tab: tab, session: session)
                            }
                            .opacity(session.selectedAuxiliaryTab(in: group.id) == tab ? 1 : 0)
                            .allowsHitTesting(session.selectedAuxiliaryTab(in: group.id) == tab)
                            .accessibilityHidden(session.selectedAuxiliaryTab(in: group.id) != tab)
                        }
                    }
                    .overlay {
                        if isDropTargeted {
                            EditorSplitPreviewOverlay(edge: hoveredDropEdge, isTabDrag: isTabDrag)
                        }
                    }
                    // A visible board owns FILE drops (they add nodes), so the
                    // group must not turn them into editor navigation. It still
                    // takes TAB drags, so an editor group can be split while a
                    // board shows: the delegate declines files in that state
                    // and the board's own target declines tabs
                    // (`EditorDropRouting`).
                    .onDrop(
                        of: selectedCanvas == nil
                            ? [.rafuEditorDrag, .fileURL] : [.rafuEditorDrag],
                        delegate: EditorDropDelegate(
                            groupID: group.id,
                            size: proxy.size,
                            hoveredEdge: $hoveredDropEdge,
                            isTargeted: $isDropTargeted,
                            session: session,
                            canvasIsVisible: selectedCanvas != nil
                        )
                    )
                }
            }
        }
    }

    private var selectedCanvas: CanvasBoardState? {
        guard session.selectedAuxiliaryTab(in: group.id) == nil,
            case .canvas(let id) = selectedTab?.resource
        else { return nil }
        return session.canvas.boards[id]
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
        guard session.selectedAuxiliaryTab(in: group.id) == nil else { return nil }
        guard case .terminal(let sessionID) = selectedTab?.resource else { return nil }
        return session.terminal.sessions.first { $0.id == sessionID }
    }

    private var selectedTerminalGroupID: TerminalGroupID? {
        guard session.selectedAuxiliaryTab(in: group.id) == nil else { return nil }
        guard case .terminalGroup(let groupID) = selectedTab?.resource else { return nil }
        return groupID
    }

    /// Resolves every visible terminal color once for this group render. The
    /// selected entry is reused by both its tab marker and the complete live
    /// group perimeter, so the two cues cannot drift in precedence or theme.
    private var terminalIdentityPresentations: [UUID: EditorTerminalIdentityPresentation] {
        var presentations: [UUID: EditorTerminalIdentityPresentation] = [:]
        for tab in group.tabs {
            guard case .terminal(let sessionID) = tab.resource,
                let controller = session.terminal.sessions.first(where: { $0.id == sessionID }),
                let sessionColor = controller.sessionColor
            else { continue }
            let color = theme.palette.color(for: sessionColor)
            presentations[sessionID] = EditorTerminalIdentityPresentation(
                color: color,
                matchesEditorBackground:
                    color.rafuHexString == theme.palette.editorBackground.rafuHexString
            )
        }
        return presentations
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

    /// Whether the drag currently hovering this group is a tab — the
    /// same-window `activeEditorDrag` cache `EditorDropDelegate.validateDrop`
    /// already reads. A cross-window drag with no cached hint falls back to
    /// "Open here", a label still correct for the common file-drop case.
    private var isTabDrag: Bool {
        if case .tab? = session.activeEditorDrag { return true }
        return false
    }

    /// GX2 hunk-peek/blame-hover wiring for `document`, threaded into
    /// `CodeEditorView`. Stage Hunk and the working-tree diff provider go
    /// through `WorkspaceSession`'s peek-scoped methods; Open Full Diff maps
    /// to the standalone diff canvas; Show in History jumps the History
    /// selection (and reveals Source Control if it isn't already open);
    /// Open Blame Canvas reuses the existing read-only blame path.
    private func gitPeekActions(for document: EditorDocument) -> GitPeekActions {
        GitPeekActions(
            workingTreeDiffProvider: { [weak session = session, weak document = document] in
                guard let session, let document else { return nil }
                return await session.workingTreeDiff(for: document)
            },
            stageHunk: { [weak session = session] hunk, diff in
                await session?.stagePeekHunk(hunk, in: diff)
            },
            openFullDiff: { [weak session = session, weak document = document] in
                guard let session, let document else { return }
                session.openWorkingTreeDiff(for: document)
            },
            showCommitInHistory: { [weak session = session] line in
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
            openBlameCanvas: { [weak session = session] in
                Task { await session?.openBlameForSelectedFile() }
            },
            isBusy: { [weak session = session] in
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
        let targeted = $isDropTargeted
        let hoveredEdge = $hoveredDropEdge
        let groupID = group.id
        let reduceMotion = reduceMotion
        return EditorDropForwarding(
            updated: { location, size in
                let edge = EditorDropGeometry.target(at: location, in: size)
                targeted.wrappedValue = true
                if edge != hoveredEdge.wrappedValue {
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.22)) {
                        hoveredEdge.wrappedValue = edge
                    }
                }
            },
            exited: {
                targeted.wrappedValue = false
                hoveredEdge.wrappedValue = nil
            },
            perform: { [weak session = session] location, size, pasteboardPayload in
                guard let session else { return false }
                let edge = EditorDropGeometry.target(at: location, in: size)
                targeted.wrappedValue = false
                hoveredEdge.wrappedValue = nil
                guard let payload = session.activeEditorDrag ?? pasteboardPayload else {
                    return false
                }
                session.clearEditorDrag()
                switch payload {
                case .tab(let id):
                    session.handleEditorTabDrop(id, on: groupID, edge: edge)
                case .file(let path):
                    session.handleEditorFileDrop(path: path, on: groupID, edge: edge)
                }
                return true
            },
            performFiles: { [weak session = session] location, size, paths in
                guard let session else { return false }
                guard !paths.isEmpty else { return false }
                let edge = EditorDropGeometry.target(at: location, in: size)
                targeted.wrappedValue = false
                hoveredEdge.wrappedValue = nil
                session.handleEditorFileDrops(paths: paths, on: groupID, edge: edge)
                return true
            }
        )
    }
}

/// Tracks the pointer during a tab, sidebar-file, or external-file drag and
/// reports the nearest split edge (or `nil` for the central "open/move in
/// place" zone) so the overlay can preview the resulting pane before the
/// drop happens. Shared by every editor group and the empty-editor
/// placeholder so tabs, tree files, and Finder files get identical drop
/// behavior — external `.fileURL` drags matter over surfaces the text
/// view's AppKit forwarding cannot cover (terminal tabs, image/video
/// previews, the empty editor).
private struct EditorDropDelegate: DropDelegate {
    let groupID: EditorGroupID
    /// `nil` for a container with no meaningful split geometry (the empty
    /// editor placeholder), which always resolves to the center zone.
    let size: CGSize?
    @Binding var hoveredEdge: EditorSplitEdge?
    @Binding var isTargeted: Bool
    let session: WorkspaceSession
    /// A board fills the group. The delegate then takes tab drags only; the
    /// board keeps file drags (see `EditorDropRouting`).
    var canvasIsVisible = false

    func validateDrop(info: DropInfo) -> Bool {
        guard canvasIsVisible else { return true }
        return info.hasItemsConforming(to: [.rafuEditorDrag])
            && EditorDropRouting.groupAccepts(
                session.activeEditorDrag, canvasIsVisible: canvasIsVisible)
    }

    func dropEntered(info: DropInfo) {
        DragDiag.note(
            "editor(SwiftUI) entered valid=\(validateDrop(info: info)) "
                + "canvasVisible=\(canvasIsVisible)")
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
        DragDiag.note("editor(SwiftUI) performDrop")
        let resolvedEdge = edge(for: info.location)
        isTargeted = false
        hoveredEdge = nil

        guard info.itemProviders(for: [.rafuEditorDrag]).first != nil else {
            // External file drag (Finder or another app): open the files at
            // the hovered edge, same as the text view's AppKit forwarding.
            return performExternalFileDrop(info: info, edge: resolvedEdge)
        }

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

    /// Loads every `.fileURL` provider, then opens the batch through
    /// `handleEditorFileDrops` (which rejects directories and applies the
    /// split edge to the first file only). Slots keep the providers' order
    /// even though the loads complete asynchronously in any order.
    private func performExternalFileDrop(info: DropInfo, edge: EditorSplitEdge?) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }

        let collector = ExternalFileDropCollector(
            expected: providers.count,
            session: session,
            groupID: groupID,
            edge: edge
        )
        for (index, provider) in providers.enumerated() {
            _ = provider.loadDataRepresentation(for: .fileURL) { data, _ in
                let path = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil)?.path }
                Task { @MainActor in
                    collector.fulfill(index: index, path: path)
                }
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

/// Order-preserving accumulator for an external multi-file drop: each
/// `.fileURL` provider load lands here (already hopped to the main actor),
/// and once every slot has reported, the surviving paths open as one batch.
@MainActor
private final class ExternalFileDropCollector {
    private var slots: [String??]
    private var remaining: Int
    private let session: WorkspaceSession
    private let groupID: EditorGroupID
    private let edge: EditorSplitEdge?

    init(expected: Int, session: WorkspaceSession, groupID: EditorGroupID, edge: EditorSplitEdge?) {
        slots = Array(repeating: nil, count: expected)
        remaining = expected
        self.session = session
        self.groupID = groupID
        self.edge = edge
    }

    func fulfill(index: Int, path: String?) {
        guard slots.indices.contains(index), slots[index] == nil else { return }
        slots[index] = .some(path)
        remaining -= 1
        guard remaining == 0 else { return }
        let paths = slots.compactMap { $0 ?? nil }
        guard !paths.isEmpty else { return }
        session.handleEditorFileDrops(paths: paths, on: groupID, edge: edge)
    }
}

/// Accumulates every visible tab row's frame (in `EditorGroupTabBar`'s named
/// coordinate space) so the reorder drop delegate can turn a pointer
/// x-coordinate into an insertion index. Last-write-wins on a colliding key
/// is fine here — a given `EditorTabID` only ever contributes one frame per
/// layout pass.
private struct TabStripFramePreferenceKey: PreferenceKey {
    static var defaultValue: [EditorTabID: CGRect] = [:]

    static func reduce(value: inout [EditorTabID: CGRect], nextValue: () -> [EditorTabID: CGRect]) {
        value.merge(nextValue()) { _, next in next }
    }
}

/// One tab's resolved hover-preview content and its anchor, published only
/// while that tab is both hovered and past the 500 ms delay. Anchors (not a
/// named coordinate space) so the reader below stays correct regardless of
/// horizontal scroll offset, matching the now-removed selected-cap seam
/// overlay's approach. Internal (not file-private): `CanvasEditorTabItem`
/// lives in a different file and needs the `tabHoverPreview` modifier below.
struct TabHoverPreviewAnchor {
    let content: TabHoverPreviewContent
    let anchor: Anchor<CGRect>
}

struct TabHoverPreviewPreferenceKey: PreferenceKey {
    static var defaultValue: TabHoverPreviewAnchor? = nil

    static func reduce(value: inout TabHoverPreviewAnchor?, nextValue: () -> TabHoverPreviewAnchor?)
    {
        value = nextValue() ?? value
    }
}

/// Shared delay/cancel logic for every tab kind that shows a hover preview.
/// `.task(id: isHovering)` is SwiftUI's own cancel-on-change: a hover that
/// ends before 500 ms elapses cancels the sleeping task instead of showing
/// anything, and a hover that ends after the preview is already visible
/// hides it immediately on the same edge.
struct TabHoverPreviewTrigger: ViewModifier {
    let isHovering: Bool
    let content: TabHoverPreviewContent

    @State private var showsPreview = false

    func body(content base: Content) -> some View {
        base
            .task(id: isHovering) {
                guard isHovering else {
                    showsPreview = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                showsPreview = true
            }
            .anchorPreference(key: TabHoverPreviewPreferenceKey.self, value: .bounds) { bounds in
                showsPreview ? TabHoverPreviewAnchor(content: content, anchor: bounds) : nil
            }
    }
}

extension View {
    func tabHoverPreview(isHovering: Bool, content: TabHoverPreviewContent) -> some View {
        modifier(TabHoverPreviewTrigger(isHovering: isHovering, content: content))
    }
}

/// Full-width shelf the floating tab cards sit inside. Window redesign phase
/// 4: tabs are detached rounded cards, not attached caps, so there is no
/// shared tab/content seam for this shelf to mask — it only owns the
/// breathing room around the cards and the one hairline border separating
/// the strip from the editor content beneath it.
private struct EditorTabShelf<Content: View>: View {
    @ViewBuilder let content: Content

    @Environment(\.rafuTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var scaledHeight = RafuMetrics.tabBarHeight

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let tabHeight = WorkbenchTextHeightPolicy.attachedTabHeight(for: scaledHeight)
        content
            .padding(.vertical, RafuMetrics.tabShelfBreathingRoom)
            .frame(
                maxWidth: .infinity,
                minHeight: WorkbenchTextHeightPolicy.tabShelfHeight(forTabHeight: tabHeight),
                alignment: .center
            )
            .background(theme.palette.tabBarBackground)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(theme.palette.borderSubtle)
                    .frame(height: RafuMetrics.hairline)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

/// The tab strip's own drop target: reorders a tab within `groupID` when
/// dragged from this same strip, or moves it here at the hovered slot when
/// dragged from a different group's strip. Scoped to `groupID` and layered
/// on the tab strip itself so a drag never reaches the group's split/move
/// delegate while hovering the strip (`EditorGroupView.body` scopes that
/// delegate to the body below the tab bar for exactly this reason).
///
/// Registered for `.rafuEditorDrag` ONLY — never `.fileURL` — so a real
/// Finder file dropped on the tab bar falls through untouched for whatever
/// handles Finder-originated drops. A `.file` case of `.rafuEditorDrag`
/// itself (the Files-navigator-to-editor payload) is also ignored here: the
/// tab strip only reorders/relocates tabs, it does not open files in place.
private struct TabStripReorderDropDelegate: DropDelegate {
    let groupID: EditorGroupID
    let orderedTabIDs: [EditorTabID]
    let tabFrames: [EditorTabID: CGRect]
    let reduceMotion: Bool
    @Binding var hoveredInsertionIndex: Int?
    let session: WorkspaceSession

    func dropEntered(info: DropInfo) {
        hoveredInsertionIndex = insertionIndex(for: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let index = insertionIndex(for: info.location)
        if index != hoveredInsertionIndex {
            if reduceMotion {
                hoveredInsertionIndex = index
            } else {
                withAnimation(.spring(duration: 0.22)) { hoveredInsertionIndex = index }
            }
        }
        // Matches `EditorDropDelegate.dropUpdated`: `.copy` is the operation
        // that reliably validates for an `.onDrag`-originated session on
        // macOS. The underlying action is always a layout reorder/move,
        // never a data copy.
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        hoveredInsertionIndex = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let index = insertionIndex(for: info.location)
        hoveredInsertionIndex = nil

        guard info.itemProviders(for: [.rafuEditorDrag]).first != nil else { return false }

        // Same-process fast path, mirroring `EditorDropDelegate.performDrop`.
        if let payload = session.activeEditorDrag {
            session.clearEditorDrag()
            guard case .tab(let value) = payload, let uuid = UUID(uuidString: value) else {
                return false
            }
            session.reorderOrMoveEditorTab(
                EditorTabID(rawValue: uuid), to: groupID, atInsertionIndex: index)
            return true
        }

        // Cross-window fallback. `action` closes over only `session`,
        // `groupID`, and the already-resolved `index` (never `self`, which
        // isn't `Sendable`) — safe to hand to the off-actor load handler
        // because it only ever runs after hopping back onto the main actor.
        let action: @MainActor @Sendable (EditorDragPayload) -> Void = {
            [session, groupID, index] payload in
            session.clearEditorDrag()
            guard case .tab(let value) = payload, let uuid = UUID(uuidString: value) else {
                return
            }
            session.reorderOrMoveEditorTab(
                EditorTabID(rawValue: uuid), to: groupID, atInsertionIndex: index)
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

    private func insertionIndex(for location: CGPoint) -> Int {
        let frames = orderedTabIDs.compactMap { tabFrames[$0] }
        return TabStripDrop.insertionIndex(forX: location.x, tabFrames: frames)
    }
}

/// Translucent preview of the pane a dragged tab would occupy — the current
/// content visually yields half the group instead of showing arrow buttons.
private struct EditorSplitPreviewOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rafuTheme) private var theme
    let edge: EditorSplitEdge?
    /// Whether the hovering drag is a tab (vs. a Files-tree/Finder file), so
    /// the center-zone label reads "Move tab to this editor group" instead
    /// of "Open here".
    var isTabDrag = false

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
                    .overlay(alignment: .top) {
                        Text(label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.palette.onAccent)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(theme.palette.accent))
                            .fixedSize()
                            .padding(.top, 14)
                    }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.22), value: edge)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var label: String {
        switch edge {
        case .leading: "Split editor left"
        case .trailing: "Split editor right"
        case .top: "Split editor up"
        case .bottom: "Split editor down"
        case nil: isTabDrag ? "Move tab to this editor group" : "Open here"
        }
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
                // Saved workspaces and recent folders: the same list as the
                // Workspaces window (⇧⌘1), opening in this window.
                welcomeCard(title: "Workspaces", width: 380) {
                    WorkspacesListView(model: .shared, session: session, placement: .welcome)
                        .frame(height: 230)
                }
                welcomeCard(title: "Shortcuts") { WelcomeShortcutHints() }
            }
        }
        .padding(40)
    }

    private func welcomeCard<Content: View>(
        title: String,
        width: CGFloat = 260,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.textSecondary)
            content()
        }
        .padding(14)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous)
                .fill(theme.palette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous)
                .strokeBorder(theme.palette.borderSubtle)
        )
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
            hint("All Workspaces", keys: "⌘⇧1")
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

    private var isTabDrag: Bool {
        if case .tab? = session.activeEditorDrag { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.palette.textMuted)
            VStack(spacing: 5) {
                Text("\(workspaceName) is open")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                Text("Click a file in the sidebar, or press ⌘⇧P for commands.")
                    .font(.callout)
                    .foregroundStyle(theme.palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if isDropTargeted {
                EditorSplitPreviewOverlay(edge: nil, isTabDrag: isTabDrag)
            }
        }
        .onDrop(
            of: [.rafuEditorDrag, .fileURL],
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
    /// Named coordinate space shared by every tab row's frame preference and
    /// the reorder drop delegate's pointer location, so both agree on the
    /// same origin regardless of horizontal scroll offset — the space is
    /// anchored to the strip's own scrolled content, not the screen, so a
    /// tab's captured frame and the drop pointer's `x` stay comparable even
    /// mid-scroll.
    private static let coordinateSpaceName = "editorTabStrip"

    @Environment(\.rafuTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tabFrames: [EditorTabID: CGRect] = [:]
    @State private var hoveredInsertionIndex: Int?
    /// Visible width of the scrolling strip. The drop target stretches to at
    /// least this width so the empty part of the bar (and an empty group's
    /// whole bar) accepts a dragged tab.
    @State private var stripViewportWidth: CGFloat = 0

    let group: EditorGroupState
    let terminalIdentities: [UUID: EditorTerminalIdentityPresentation]
    @Bindable var session: WorkspaceSession

    var body: some View {
        EditorTabShelf {
            HStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: RafuMetrics.space1) {
                        ForEach(group.tabs) { tab in
                            tabRow(for: tab)
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: TabStripFramePreferenceKey.self,
                                            value: [
                                                tab.id: proxy.frame(
                                                    in: .named(Self.coordinateSpaceName))
                                            ]
                                        )
                                    }
                                }
                        }
                        ForEach(session.auxiliaryTabs(in: group.id)) { tab in
                            AuxiliaryEditorTabItem(
                                tab: tab,
                                isSelected: session.selectedAuxiliaryTab(in: group.id) == tab,
                                select: { session.selectAuxiliaryTab(tab) },
                                close: { session.closeAuxiliaryTab(tab) }
                            )
                        }
                    }
                    .coordinateSpace(.named(Self.coordinateSpaceName))
                    // Forces the enclosing NSScrollView's legacy scroller off
                    // even when System Settings requests always-visible bars.
                    .background(ScrollerHidingConfigurator())
                    .onPreferenceChange(TabStripFramePreferenceKey.self) { tabFrames = $0 }
                    .overlay(alignment: .topLeading) { insertionIndicator }
                    // The target covers the whole visible strip, not only the
                    // tabs: dropping past the last tab appends, and an empty
                    // group's bar still receives a tab. The leading alignment
                    // keeps the content origin, so the tab frames above stay
                    // valid for the drop location.
                    .frame(minWidth: stripViewportWidth, alignment: .leading)
                    .contentShape(Rectangle())
                    // The structurally scoped reorder target remains below
                    // the group's body split/move target.
                    .onDrop(
                        of: [.rafuEditorDrag],
                        delegate: TabStripReorderDropDelegate(
                            groupID: group.id,
                            orderedTabIDs: group.tabs.map(\.id),
                            tabFrames: tabFrames,
                            reduceMotion: reduceMotion,
                            hoveredInsertionIndex: $hoveredInsertionIndex,
                            session: session
                        )
                    )
                }
                .scrollIndicators(.hidden)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    stripViewportWidth = $0
                }
                // Tabs scroll under a trailing fade, so the fixed controls
                // below never overlap (or clip) a tab or its close button.
                .overlay(alignment: .trailing) {
                    LinearGradient(
                        colors: [
                            theme.palette.tabBarBackground.opacity(0),
                            theme.palette.tabBarBackground,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 16)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .layoutPriority(0)
                newTabMenu
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
                    .fixedSize()
                }
                if group.tabs.count > 1 {
                    overflowTabMenu
                }
            }
        }
        // Read above the shelf's own bounds (not clipped — nothing in this
        // view tree clips, and this shelf is the first thing in its
        // editor group's VStack, so there is no later sibling to hide
        // behind): the card's center sits at the shelf's own top edge, which
        // in practice floats it just above the strip regardless of which tab
        // is hovered, since every tab sits at the same shallow row.
        .overlayPreferenceValue(TabHoverPreviewPreferenceKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor {
                    let frame = proxy[anchor.anchor]
                    TabHoverPreviewCard(content: anchor.content)
                        .fixedSize()
                        .position(
                            x: min(max(frame.midX, 130), max(130, proxy.size.width - 130)),
                            y: 0
                        )
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: anchor != nil)
        }
    }

    private var selectedDocument: EditorDocument? {
        guard session.selectedAuxiliaryTab(in: group.id) == nil,
            let selectedTabID = group.selectedTabID,
            let tab = group.tabs.first(where: { $0.id == selectedTabID })
        else { return nil }
        return session.document(for: tab)
    }

    /// The strip's trailing "+": a direct click opens a new untitled file
    /// (the same destination as ⌘N), and the attached chevron lists every
    /// other canvas kind this group can host. Matches the split-button
    /// convention already used by `WorkspaceTerminalsPanelView.newTerminalControl`.
    private var newTabMenu: some View {
        Menu {
            Button("New File", systemImage: "doc.badge.plus") {
                session.newUntitledDocument()
            }
            Button("New Terminal", systemImage: "terminal") {
                session.editorLayout.focus(group.id)
                session.newTerminalTab()
            }
            .disabled(session.isTerminalGroupModalInputBlocked)
            Button("New Terminal Group", systemImage: "rectangle.3.group") {
                session.editorLayout.focus(group.id)
                session.newTerminalGroup()
            }
            .disabled(session.isTerminalGroupModalInputBlocked)
            Button("New Ensemble", systemImage: "square.on.square.dashed") {
                session.editorLayout.focus(group.id)
                session.requestNewCanvas()
            }
            .disabled(session.rootURL == nil)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        } primaryAction: {
            session.newUntitledDocument()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("New Tab. Use the arrow for a terminal, Terminal Group, or Ensemble.")
        .accessibilityLabel("New Tab")
    }

    @ViewBuilder
    private func tabRow(for tab: EditorTabState) -> some View {
        switch tab.resource {
        case .file:
            if let document = session.document(for: tab) {
                EditorTabItem(
                    tabID: tab.id,
                    groupID: group.id,
                    document: document,
                    isSelected: tab.id == group.selectedTabID
                        && session.selectedAuxiliaryTab(in: group.id) == nil,
                    session: session
                )
            }
        case .terminal(let sessionID):
            // Issue #4: same tab chrome as a file tab (icon, label, close
            // button, attached selected cap) — just backed by a live
            // terminal session instead of an `EditorDocument`. Reordered as
            // a peer of file tabs (ADR 0014): the frame-capture `ForEach`
            // above treats every row identically, and reordering never
            // touches park/close semantics.
            if let controller = session.terminal.sessions.first(where: { $0.id == sessionID }) {
                EditorTerminalTabItem(
                    tabID: tab.id,
                    groupID: group.id,
                    controller: controller,
                    identity: terminalIdentities[sessionID],
                    isSelected: tab.id == group.selectedTabID
                        && session.selectedAuxiliaryTab(in: group.id) == nil,
                    session: session
                )
            }
        case .terminalGroup(let terminalGroupID):
            if let snapshot = session.terminal.terminalGroup(terminalGroupID) {
                EditorTerminalGroupTabItem(
                    tabID: tab.id, groupID: group.id, snapshot: snapshot,
                    isSelected: tab.id == group.selectedTabID
                        && session.selectedAuxiliaryTab(in: group.id) == nil, session: session)
            }
        case .canvas(let id):
            if let board = session.canvas.boards[id] {
                CanvasEditorTabItem(
                    tab: tab, groupID: group.id, board: board,
                    isSelected: tab.id == group.selectedTabID
                        && session.selectedAuxiliaryTab(in: group.id) == nil,
                    session: session)
            }
        case .restorable:
            EmptyView()
        }
    }

    /// A thin accent bar marking the slot a dragged tab would land in —
    /// SwiftUI's `.rafuEditorDrag` counterpart to `EditorSplitPreviewOverlay`.
    /// Positioned from the ordered tab frames captured by
    /// `TabStripFramePreferenceKey`; `nil` while nothing is hovering the
    /// strip.
    @ViewBuilder
    private var insertionIndicator: some View {
        if let hoveredInsertionIndex {
            let frames = group.tabs.compactMap { tabFrames[$0.id] }
            let x = indicatorX(forInsertionIndex: hoveredInsertionIndex, tabFrames: frames)
            Rectangle()
                .fill(theme.palette.accent)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .offset(x: x - 1)
                .accessibilityHidden(true)
        }
    }

    /// The x-coordinate (in the strip's named coordinate space) for the
    /// insertion-indicator bar: flush with the leading edge of the first tab
    /// when inserting at the start, flush with the trailing edge of the last
    /// tab when inserting at the end, and centered in the gap between two
    /// tabs otherwise.
    private func indicatorX(forInsertionIndex index: Int, tabFrames: [CGRect]) -> CGFloat {
        guard !tabFrames.isEmpty else { return 0 }
        if index <= 0 { return tabFrames[0].minX }
        if index >= tabFrames.count { return tabFrames[tabFrames.count - 1].maxX }
        return (tabFrames[index - 1].maxX + tabFrames[index].minX) / 2
    }

    /// Discoverable overflow affordance: pinned OUTSIDE the horizontally
    /// scrolling tab strip so it never scrolls with the tabs, listing every
    /// tab in `group.tabs` so a tab scrolled out of view is still reachable
    /// without hunting through the scroller. Hidden for a single tab, where
    /// there is nothing to disambiguate.
    private var overflowTabMenu: some View {
        Menu {
            ForEach(group.tabs) { tab in
                overflowTabMenuItem(for: tab)
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.trailing, 4)
        .help("Show all tabs")
        .accessibilityLabel("Show all tabs")
    }

    @ViewBuilder
    private func overflowTabMenuItem(for tab: EditorTabState) -> some View {
        switch tab.resource {
        case .file:
            if let document = session.document(for: tab) {
                overflowTabMenuButton(
                    title: document.displayName,
                    glyph: FileIconProvider.fileIcon(named: document.displayName).symbol,
                    isDirty: document.isDirty,
                    tab: tab
                )
            }
        case .terminal(let sessionID):
            if let controller = session.terminal.sessions.first(where: { $0.id == sessionID }) {
                overflowTabMenuButton(
                    title: TerminalSessionPresentation.tabLabel(controller.presentedTitle),
                    glyph: "terminal", isDirty: false, tab: tab)
            }
        case .terminalGroup(let terminalGroupID):
            if let snapshot = session.terminal.terminalGroup(terminalGroupID) {
                overflowTabMenuButton(
                    title: snapshot.name.rawValue, glyph: "rectangle.3.group", isDirty: false,
                    tab: tab)
            }
        case .canvas(let id):
            overflowTabMenuButton(
                title: session.canvas.boards[id]?.title ?? "Ensemble", glyph: "rectangle.3.group",
                isDirty: false, tab: tab)
        case .restorable:
            EmptyView()
        }
    }

    /// One row of the tab list: the tab's glyph, its name, and a trailing dot
    /// when the document has unsaved changes. The selected tab keeps the check
    /// mark in place of its glyph (a menu row carries one image).
    @ViewBuilder
    private func overflowTabMenuButton(
        title: String, glyph: String, isDirty: Bool, tab: EditorTabState
    ) -> some View {
        let isSelected = tab.id == group.selectedTabID
        Button {
            session.selectEditorTab(tab.id, in: group.id)
        } label: {
            Label(isDirty ? "\(title) •" : title, systemImage: isSelected ? "checkmark" : glyph)
        }
        .accessibilityValue(
            [isSelected ? "Selected" : nil, isDirty ? "Unsaved changes" : nil]
                .compactMap(\.self).joined(separator: ", "))
    }
}

/// Secondary stitched motif on the selected cap's top edge. The attached fill
/// and open-bottom outline remain the primary grayscale selection signal.
private struct StitchedAccentEdge: View {
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
    let openDiff: GitOpenDiff
    @Bindable var session: WorkspaceSession

    var body: some View {
        VStack(spacing: 0) {
            EditorTabShelf {
                HStack(spacing: 0) {
                    GitDiffTabItem(
                        openDiff: openDiff,
                        isSelected: true,
                        select: session.selectGitDiff,
                        close: session.closeGitDiff
                    )
                    Spacer()
                }
            }
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
            EditorTabShelf {
                HStack(spacing: 0) {
                    AttachedWorkbenchTab(isSelected: true, usesDocumentWidth: true) {
                        HStack(spacing: 6) {
                            Image(systemName: "person.text.rectangle")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.palette.info)
                                .accessibilityHidden(true)
                            Text("Blame • \(fileName)")
                                .lineLimit(1)
                                .help("Blame • \(fileName)")
                            AttachedWorkbenchTabCloseButton(
                                accessibilityLabel: "Close Blame • \(fileName)",
                                help: "Close Blame • \(fileName)",
                                action: close
                            )
                            .opacity(isHoveringTab ? 1 : 0.75)
                        }
                    }
                    .overlay(alignment: .top) {
                        StitchedAccentEdge(color: theme.palette.accent)
                    }
                    .help("Blame • \(fileName)")
                    .accessibilityLabel("Blame • \(fileName)")
                    Spacer()
                }
            }
            .onHover { isHoveringTab = $0 }
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
        AttachedWorkbenchTab(isSelected: isSelected, usesDocumentWidth: true, select: select) {
            HStack(spacing: 6) {
                Button(action: select) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.palette.info)
                            .accessibilityHidden(true)
                        Text(openDiff.title)
                            .lineLimit(1)
                            .help(openDiff.title)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(openDiff.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                AttachedWorkbenchTabCloseButton(
                    accessibilityLabel: "Close \(openDiff.title)",
                    help: "Close \(openDiff.title)",
                    presentation: EditorTabAccessory.resolve(
                        isSelected: isSelected,
                        isHovering: isHovering,
                        isDirty: false
                    ),
                    action: close
                )
            }
        }
        .background {
            if isHovering && !isSelected {
                RoundedRectangle(cornerRadius: RafuMetrics.radiusWorkbenchTab, style: .continuous)
                    .fill(theme.palette.hover.opacity(0.6))
            }
        }
        .overlay(alignment: .top) {
            if isSelected {
                StitchedAccentEdge(color: theme.palette.accent)
            }
        }
        .onHover { isHovering = $0 }
        .help(openDiff.title)
        .accessibilityElement(children: .contain)
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

    /// One header (G8): path breadcrumb, the real comparison, and "+n −n".
    /// The tab already carries the file title, so it is not repeated here.
    private var diffHeader: some View {
        let components = GitDiffHeaderPresentation.breadcrumb(for: openDiff.diff.path)
        let fileName = (openDiff.diff.path as NSString).lastPathComponent
        return RafuCardHeaderRow {
            HStack(spacing: 6) {
                FileIconView(icon: FileIconProvider.fileIcon(named: fileName), size: 12)
                    .accessibilityHidden(true)
                ForEach(Array(components.enumerated()), id: \.offset) { item in
                    if item.offset > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(theme.palette.textMuted)
                            .accessibilityHidden(true)
                    }
                    let isLast = item.offset == components.count - 1
                    Text(item.element)
                        .font(.system(size: 12, weight: isLast ? .semibold : .regular))
                        .foregroundStyle(
                            isLast ? theme.palette.textPrimary : theme.palette.textSecondary
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("·")
                    .foregroundStyle(theme.palette.textMuted)
                    .accessibilityHidden(true)
                Text(GitDiffHeaderPresentation.comparisonLabel(for: openDiff.scope))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(openDiff.diff.path), \(GitDiffHeaderPresentation.comparisonLabel(for: openDiff.scope))"
            )
        } trailing: {
            diffStats
        }
    }

    private var diffStats: some View {
        let counts = GitDiffHeaderPresentation.lineCounts(for: openDiff.diff)
        return HStack(spacing: 6) {
            RafuChip(
                text: "+\(counts.added)", foreground: theme.palette.gitAdded, monospacedDigit: true)
            RafuChip(
                text: "−\(counts.deleted)", foreground: theme.palette.gitDeleted,
                monospacedDigit: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(counts.added) lines added, \(counts.deleted) lines removed")
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
            // G8: no decorative "···" — the diff model has a fixed context
            // size, so there is no real "Show More Context" action to offer.
            Text(hunk.header)
                .font(.caption.monospaced())
                .foregroundStyle(theme.palette.textSecondary)
            Spacer(minLength: 12)
            if let action = hunkAction {
                Button(action.title) {
                    perform(action, on: hunk)
                }
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
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
    private static let hoverDelay: Duration = EditorHoverTiming.documentationDelay

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
    /// This tab's own identity for the dimmed source ghost while it is
    /// being dragged — stable for the tab's lifetime, compared against
    /// `session.dragInFlight`.
    @State private var dragToken = RafuDragSourceToken()

    let tabID: EditorTabID
    let groupID: EditorGroupID
    let document: EditorDocument
    let isSelected: Bool
    @Bindable var session: WorkspaceSession

    var body: some View {
        let icon = FileIconProvider.fileIcon(named: document.displayName)
        let selectTab = { session.selectEditorTabFromClick(tabID, in: groupID) }
        AttachedWorkbenchTab(isSelected: isSelected, usesDocumentWidth: true, select: selectTab) {
            HStack(spacing: 6) {
                Button {
                    session.selectEditorTabFromClick(tabID, in: groupID)
                } label: {
                    HStack(spacing: 6) {
                        FileIconView(icon: icon, size: 13)
                            .fixedSize()
                        Text(document.displayName)
                            .lineLimit(1)
                            .foregroundStyle(
                                isSelected
                                    ? theme.palette.textPrimary : theme.palette.textSecondary
                            )
                            .layoutPriority(1)
                            .help(document.displayName)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    isSelected ? theme.palette.textPrimary : theme.palette.textSecondary
                )
                .layoutPriority(1)
                .accessibilityLabel(document.displayName)
                .accessibilityValue(documentTabAccessibilityValue)
                .accessibilityAddTraits(isSelected ? .isSelected : [])

                AttachedWorkbenchTabCloseButton(
                    accessibilityLabel: "Close \(document.displayName)",
                    help: "Close \(document.displayName)",
                    presentation: EditorTabAccessory.resolve(
                        isSelected: isSelected,
                        isHovering: isHovering,
                        isDirty: document.isDirty
                    )
                ) {
                    session.requestClose(document)
                }
                .fixedSize()
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .background {
            if isHovering && !isSelected {
                RoundedRectangle(cornerRadius: RafuMetrics.radiusWorkbenchTab, style: .continuous)
                    .fill(theme.palette.hover.opacity(0.6))
            }
        }
        .overlay(alignment: .top) {
            if isSelected {
                StitchedAccentEdge(color: theme.palette.accent)
            }
        }
        .onHover { isHovering = $0 }
        .tabHoverPreview(
            isHovering: isHovering,
            content: TabHoverPreviewContentBuilder.file(
                title: document.displayName,
                workspaceRelativePath: session.relativePath(for: document.url)
            )
        )
        .opacity(session.dragInFlight == dragToken ? 0.4 : 1)
        .onDrag(
            {
                session.beginDragSourceTracking(dragToken)
                return session.beginEditorDrag(.tab(id: tabID.rawValue.uuidString))
            },
            preview: {
                RafuDragPreviewLabel(
                    icon: FileIconView(icon: icon), title: document.displayName)
            }
        )
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
        .help(document.displayName)
        .accessibilityElement(children: .contain)
    }

    private var documentTabAccessibilityValue: String {
        [
            isSelected ? "Selected" : nil,
            document.isDirty ? "Unsaved changes" : nil,
        ]
        .compactMap(\.self)
        .joined(separator: ", ")
    }
}

/// One terminal controller's live agent status and the date its underlying
/// tracked session last changed (for the activity dot and the hover
/// preview's elapsed label), resolved via its enclosing Terminal Group pane
/// — the same `CanvasCardCommands.agentCardStatus(pane:in:)` the Ensemble
/// card header, the Canvas List row, and the titlebar's agent summary
/// already share, so a terminal's status can never read differently in two
/// places. `(nil, nil)` for an ordinary shell no session has matched, or a
/// controller whose group/pane cannot be found (should not happen for a
/// live tab, but a missing identity is never worth a crash).
private func terminalAgentActivity(
    for controller: WorkspaceTerminalController, in session: WorkspaceSession
) -> (status: AgentCardStatus?, updatedAt: Date?) {
    guard let (groupID, paneID) = session.terminal.terminalGroupAndPane(containing: controller.id),
        let group = session.terminal.terminalGroup(groupID),
        let pane = group.panes.first(where: { $0.id == paneID })
    else { return (nil, nil) }
    let status = CanvasCardCommands.agentCardStatus(pane: pane, in: session)
    let updatedAt = AgentActivityStore.shared.trackedSession(for: controller)?.updatedAt
    return (status, updatedAt)
}

/// Issue #4: a terminal tab, presented with the EXACT SAME chrome as
/// `EditorTabItem` (icon, label, close button, hover, attached selected cap,
/// drag/split context menu) — just backed by a live
/// `WorkspaceTerminalController` instead of an `EditorDocument`. This tab's
/// own ✕/context-menu "Close" always terminates the shell
/// (`session.closeTerminalTab`); there is no dirty-state confirmation, since
/// a terminal has no unsaved buffer. Hiding without killing the shell is a
/// separate verb (⌃`/`toggleTerminal` → `session.hideTerminalTab`), not
/// reachable from this tab item — see terminal-manager.md T-A.
private struct EditorTerminalTabItem: View {
    @Environment(\.rafuTheme) private var theme
    @State private var isHovering = false
    /// This tab's own identity for the dimmed source ghost while it is
    /// being dragged — stable for the tab's lifetime, compared against
    /// `session.dragInFlight`.
    @State private var dragToken = RafuDragSourceToken()

    let tabID: EditorTabID
    let groupID: EditorGroupID
    @Bindable var controller: WorkspaceTerminalController
    let identity: EditorTerminalIdentityPresentation?
    let isSelected: Bool
    @Bindable var session: WorkspaceSession

    var body: some View {
        let title = TerminalSessionPresentation.tabLabel(controller.presentedTitle)
        let previewAgent = controller.resolvedAgentProvider
        let selectTab = { session.selectEditorTab(tabID, in: groupID) }
        let activity = terminalAgentActivity(for: controller, in: session)
        let activityKind = EditorTabActivityKind.from(activity.status)
        AttachedWorkbenchTab(isSelected: isSelected, usesDocumentWidth: true, select: selectTab) {
            HStack(spacing: 6) {
                Button {
                    session.selectEditorTab(tabID, in: groupID)
                } label: {
                    HStack(spacing: 6) {
                        // An agent terminal shows its VENDOR mark; the generic
                        // terminal glyph remains the login-shell fallback.
                        if let provider = controller.resolvedAgentProvider {
                            AgentIconView(cli: provider, size: 13)
                                .fixedSize()
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: "terminal")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(theme.palette.textSecondary)
                                .fixedSize()
                                .accessibilityHidden(true)
                        }
                        Text(title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(
                                isSelected
                                    ? theme.palette.textPrimary : theme.palette.textSecondary
                            )
                            .layoutPriority(1)
                            .help(title)
                        // Exited remains textual in accessibility and in the
                        // content overlay; the dot is only a redundant cue.
                        if TerminalSessionPresentation.isExited(controller.status) {
                            Circle()
                                .fill(theme.palette.textMuted)
                                .frame(width: 6, height: 6)
                                .fixedSize()
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    isSelected ? theme.palette.textPrimary : theme.palette.textSecondary
                )
                .layoutPriority(1)
                .accessibilityLabel(title)
                .accessibilityValue(terminalTabAccessibilityValue(status: activity.status))
                .accessibilityAddTraits(isSelected ? .isSelected : [])

                AttachedWorkbenchTabCloseButton(
                    accessibilityLabel: "Close \(title)",
                    help: "Close \(title)",
                    presentation: EditorTabAccessory.resolve(
                        isSelected: isSelected,
                        isHovering: isHovering,
                        isDirty: false,
                        activity: activityKind
                    )
                ) {
                    session.closeTerminalTab(tabID)
                }
                .fixedSize()
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .background {
            if isHovering && !isSelected {
                RoundedRectangle(cornerRadius: RafuMetrics.radiusWorkbenchTab, style: .continuous)
                    .fill(theme.palette.hover.opacity(0.6))
            }
        }
        .overlay(alignment: .top) {
            if isSelected {
                StitchedAccentEdge(color: theme.palette.accent)
            }
        }
        .overlay(alignment: .leading) {
            // This exact resolved identity value also surrounds the selected
            // live tile; it has no independent precedence or fallback.
            if let identity {
                Rectangle()
                    .fill(identity.color)
                    .frame(width: 2)
                    .accessibilityHidden(true)
            }
        }
        .onHover { isHovering = $0 }
        .tabHoverPreview(
            isHovering: isHovering,
            content: TabHoverPreviewContentBuilder.terminal(
                title: title,
                shellOrAgentName: previewAgent?.displayName ?? controller.shellDisplayName,
                status: activity.status,
                elapsedLabel: activity.updatedAt.map {
                    AgentCardElapsed.label(since: $0, now: AgentActivityStore.shared.now)
                }
            )
        )
        .opacity(session.dragInFlight == dragToken ? 0.4 : 1)
        .onDrag(
            {
                session.beginDragSourceTracking(dragToken)
                return session.beginEditorDrag(.tab(id: tabID.rawValue.uuidString))
            },
            preview: {
                RafuDragPreviewLabel(
                    icon: Group {
                        if let previewAgent {
                            AgentIconView(cli: previewAgent, size: 13)
                        } else {
                            Image(systemName: "terminal").font(.system(size: 13, weight: .medium))
                        }
                    }, title: title)
            }
        )
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
        .help("\(title)\n\(controller.currentDirectoryPath ?? controller.startingDirectory)")
    }

    private func terminalTabAccessibilityValue(status: AgentCardStatus?) -> String {
        [
            isSelected ? "Selected" : nil,
            TerminalSessionPresentation.isExited(controller.status) ? "Shell exited" : nil,
            status?.word,
        ]
        .compactMap(\.self)
        .joined(separator: ", ")
    }
}

/// One editor resource for a complete Terminal Group. Pane count and bell
/// count are derived from the immutable group snapshot and the existing
/// controller statuses; neither requires terminal output or view mounting.
private struct EditorTerminalGroupTabItem: View {
    @Environment(\.rafuTheme) private var theme
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var renameText = ""
    @FocusState private var renameFieldFocused: Bool
    /// This tab's own identity for the dimmed source ghost while it is
    /// being dragged — stable for the tab's lifetime, compared against
    /// `session.dragInFlight`.
    @State private var dragToken = RafuDragSourceToken()

    let tabID: EditorTabID
    let groupID: EditorGroupID
    let snapshot: TerminalGroupSnapshot
    let isSelected: Bool
    @Bindable var session: WorkspaceSession

    private var attentionCount: Int {
        snapshot.panes.reduce(into: 0) { count, pane in
            guard let controller = session.terminal.terminalController(for: pane.id),
                controller.status == .bell
            else { return }
            count += 1
        }
    }

    /// The agent in the focused pane, when the group still has its automatic
    /// name: the tab then shows the agent's mark and name (or its task
    /// title) instead of "Terminal Group 2". A user-chosen name always wins.
    private var focusedAgent: (cli: ConductorCLIID, title: String)? {
        guard TerminalNaming.isAutomaticGroupName(snapshot.name.rawValue),
            let controller = session.terminal.terminalController(for: snapshot.focusedPaneID),
            controller.hasLiveProcess,
            let cli = controller.resolvedAgentProvider
        else { return nil }
        let title = TerminalSessionPresentation.agentTitle(
            reportedTitle: controller.userName ?? controller.reportedTitle, provider: cli,
            shellName: controller.shellDisplayName)
        return (cli, title)
    }

    /// The focused pane's agent status (window redesign phase 4b): the same
    /// precedence `AgentCardStatus` already resolves for its Ensemble card,
    /// just mapped onto this Terminal Group tab's accessory slot and hover
    /// preview. Multi-pane attention already has its own bell badge above
    /// (pane-status `.bell`, independent of any matched agent session); this
    /// is a second, narrower signal and the two are not meant to agree.
    private var focusedPaneActivity: (status: AgentCardStatus?, updatedAt: Date?) {
        guard let pane = snapshot.panes.first(where: { $0.id == snapshot.focusedPaneID })
        else { return (nil, nil) }
        let status = CanvasCardCommands.agentCardStatus(pane: pane, in: session)
        let updatedAt = session.terminal.terminalController(for: pane.id).flatMap {
            AgentActivityStore.shared.trackedSession(for: $0)?.updatedAt
        }
        return (status, updatedAt)
    }

    var body: some View {
        let agent = focusedAgent
        let title = agent?.title ?? snapshot.name.rawValue
        let selectTab = { selectOrRename(title: title) }
        let activity = focusedPaneActivity
        let activityKind = EditorTabActivityKind.from(activity.status)
        AttachedWorkbenchTab(isSelected: isSelected, usesDocumentWidth: true, select: selectTab) {
            HStack(spacing: 6) {
                if let agent {
                    AgentIconView(cli: agent.cli, size: 13)
                        .fixedSize()
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "rectangle.3.group")
                        .foregroundStyle(theme.palette.textSecondary)
                        .accessibilityHidden(true)
                }
                if isRenaming {
                    TextField("Terminal Group name", text: $renameText)
                        .textFieldStyle(.plain)
                        .frame(minWidth: 100, maxWidth: 180)
                        .focused($renameFieldFocused)
                        .defaultFocus($renameFieldFocused, true)
                        .accessibilityLabel("Rename Terminal Group")
                        .onSubmit(commitRename)
                        .onExitCommand(perform: cancelRename)
                } else {
                    Button {
                        selectOrRename(title: title)
                    } label: {
                        Text(title).lineLimit(1).truncationMode(.middle)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Terminal Group \(title)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityValue(
                        [
                            isSelected ? "Selected" : nil,
                            snapshot.panes.count > 1 ? "\(snapshot.panes.count) panes" : nil,
                            attentionCount > 0
                                ? "\(attentionCount) \(attentionCount == 1 ? "pane needs" : "panes need") attention"
                                : nil,
                            activity.status?.word,
                        ]
                        .compactMap(\.self).joined(separator: ", "))
                }
                if !isRenaming {
                    if snapshot.panes.count > 1 {
                        Text("\(snapshot.panes.count)")
                            .font(.caption.weight(.semibold))
                            .accessibilityLabel("\(snapshot.panes.count) panes")
                    }
                    if attentionCount > 0 {
                        Image(systemName: "bell.fill")
                            .font(.caption2)
                            .accessibilityLabel(
                                "\(attentionCount) \(attentionCount == 1 ? "pane needs" : "panes need") attention"
                            )
                    }
                }
                AttachedWorkbenchTabCloseButton(
                    accessibilityLabel: "Close Terminal Group \(title)",
                    help: "Close \(title)",
                    presentation: EditorTabAccessory.resolve(
                        isSelected: isSelected,
                        isHovering: isHovering,
                        isDirty: false,
                        activity: activityKind
                    )
                ) {
                    session.requestTerminalGroupClose(snapshot.id)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .onHover { isHovering = $0 }
        .tabHoverPreview(
            isHovering: isHovering,
            content: TabHoverPreviewContentBuilder.terminal(
                title: title,
                shellOrAgentName: agent?.cli.displayName ?? "Terminal Group",
                status: activity.status,
                elapsedLabel: activity.updatedAt.map {
                    AgentCardElapsed.label(since: $0, now: AgentActivityStore.shared.now)
                }
            )
        )
        .opacity(session.dragInFlight == dragToken ? 0.4 : 1)
        .onDrag(
            {
                session.beginDragSourceTracking(dragToken)
                return session.beginEditorDrag(.tab(id: tabID.rawValue.uuidString))
            },
            preview: {
                RafuDragPreviewLabel(
                    icon: Group {
                        if let agent {
                            AgentIconView(cli: agent.cli, size: 13)
                        } else {
                            Image(systemName: "rectangle.3.group")
                        }
                    }, title: title)
            }
        )
        .contextMenu {
            Button("Rename", systemImage: "pencil") { beginRename(title: title) }
            Divider()
            Button("Split Left", systemImage: "rectangle.split.2x1") {
                session.splitEditorTab(tabID, at: .leading)
            }
            Button("Split Right", systemImage: "rectangle.split.2x1") {
                session.splitEditorTab(tabID, at: .trailing)
            }
            Button("Move to Ensemble", systemImage: "square.on.square.dashed") {
                session.moveTerminalGroupToCurrentEnsemble(snapshot.id)
            }
            .disabled(!session.canMoveTerminalGroupToEnsemble(snapshot.id))
            Divider()
            Button("Close") { session.requestTerminalGroupClose(snapshot.id) }
        }
        .accessibilityElement(children: .contain)
    }

    /// One click handler for the whole tab: select at once, and rename on the
    /// second click of a double-click. A separate `onTapGesture(count: 2)`
    /// would delay every single click by the double-click interval.
    private func selectOrRename(title: String) {
        session.selectEditorTab(tabID, in: groupID)
        if TabClickIntent.current() == .selectAndRename { beginRename(title: title) }
    }

    private func beginRename(title: String) {
        renameText = title
        isRenaming = true
        renameFieldFocused = true
    }

    private func commitRename() {
        session.renameTerminalGroup(snapshot.id, to: renameText)
        isRenaming = false
        renameFieldFocused = false
    }

    private func cancelRename() {
        isRenaming = false
        renameFieldFocused = false
    }
}

private struct EditorDocumentView: View {
    @Environment(\.rafuTheme) private var theme
    @Bindable var document: EditorDocument
    var isVisible: Bool = true
    let findState: DocumentFindState
    var requestFind: (@MainActor () -> Void)? = nil
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
                GuardBannerView(document: document, isVisible: isVisible)
            }
            Group {
                if document.isVideo {
                    VideoPreviewView(url: document.url)
                } else if document.isBitmapImage {
                    ImagePreviewView(url: document.url)
                } else if document.isMarkdown || document.isSVG {
                    MarkdownEditorPresentation(
                        document: document,
                        isVisible: isVisible,
                        findState: findState,
                        theme: theme,
                        requestFind: requestFind,
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
                        isVisible: isVisible,
                        theme: theme,
                        findState: findState,
                        requestFind: requestFind,
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
struct GuardBannerView: View {
    @Environment(\.rafuTheme) private var theme
    let document: EditorDocument
    let isVisible: Bool

    var body: some View {
        // The document editor stays mounted for TextKit. Its combined banner
        // must leave the tree while inactive, so it cannot remain in AX output.
        if isVisible { banner }
    }

    private var banner: some View {
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
    var isVisible: Bool = true
    let findState: DocumentFindState
    let theme: RafuTheme
    var requestFind: (@MainActor () -> Void)? = nil
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
            isVisible: isVisible,
            theme: theme,
            findState: findState,
            requestFind: requestFind,
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

/// Find / replace bar. Layout (Xcode and Safari order): the field first, then
/// the result count, previous/next, the option toggles, and a trailing Done.
/// The replace row reuses the same leading column and field width so the two
/// fields align. Option toggles are neutral 24 x 22 icons; the field draws the
/// theme focus ring (never system blue).
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

    /// Shared by both rows so the find and replace fields align.
    private static let disclosureColumnWidth: CGFloat = 22
    private static let fieldMinWidth: CGFloat = 260
    private static let fieldMaxWidth: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(
                    showsReplace ? "Hide Replace" : "Show Replace",
                    systemImage: showsReplace ? "chevron.down" : "chevron.right"
                ) { showsReplace.toggle() }
                .buttonStyle(RafuIconButtonStyle(size: Self.disclosureColumnWidth, iconSize: 10))
                .help(showsReplace ? "Hide Replace" : "Show Replace")
                TextField("Find", text: $state.query)
                    .textFieldStyle(.plain)
                    .rafuField(isFocused: focusedField == .query)
                    .frame(minWidth: Self.fieldMinWidth, maxWidth: Self.fieldMaxWidth)
                    .focused($focusedField, equals: .query)
                    .onSubmit { state.findNext() }
                    .onChange(of: state.queryFocusRequest, initial: true) { _, request in
                        guard request > 0 else { return }
                        focusedField = .query
                    }
                Text(matchSummary).font(.caption.monospacedDigit())
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
                    .frame(minWidth: 52, alignment: .leading)
                Button("Previous Match", systemImage: "chevron.left") { state.findPrevious() }
                    .buttonStyle(RafuIconButtonStyle(size: 22))
                    .help("Previous Match")
                Button("Next Match", systemImage: "chevron.right") { state.findNext() }
                    .buttonStyle(RafuIconButtonStyle(size: 22))
                    .help("Next Match")
                // A `ViewBuilder` block holds at most ten children, so the
                // option toggles are grouped. `Group` adds no layout of its own.
                Group {
                    RafuOptionToggle(
                        glyph: .text("Aa"), label: "Match Case",
                        isOn: optionBinding(.caseSensitive))
                    RafuOptionToggle(
                        glyph: .text("ab", underlined: true), label: "Whole Word",
                        isOn: optionBinding(.wholeWord))
                    RafuOptionToggle(
                        glyph: .text(".*", monospaced: true), label: "Regular Expression",
                        isOn: optionBinding(.regularExpression))
                    RafuOptionToggle(
                        glyph: .symbol("selection.pin.in.out"), label: "Find in Selection",
                        isOn: Binding(
                            get: { state.isLimitedToSelection },
                            set: { state.setLimitedToSelection($0) }
                        ))
                }
                Spacer(minLength: 0)
                Button("Done", action: close)
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    .help("Close Find")
            }
            if showsReplace {
                HStack(spacing: 6) {
                    Color.clear.frame(width: Self.disclosureColumnWidth, height: 1)
                    TextField("Replace", text: $state.replacement)
                        .textFieldStyle(.plain)
                        .rafuField(isFocused: focusedField == .replacement)
                        .frame(minWidth: Self.fieldMinWidth, maxWidth: Self.fieldMaxWidth)
                        .focused($focusedField, equals: .replacement)
                        .onSubmit { state.replaceCurrent() }
                    Button("Replace") { state.replaceCurrent() }
                        .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    Button("Replace All") { state.replaceAll() }
                        .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    Spacer(minLength: 0)
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
        .onExitCommand {
            state.focusEditor()
            close()
        }
    }

    private var matchSummary: String {
        FindBarPresentation.matchSummary(
            matchCount: state.matchCount, currentIndex: state.currentMatchIndex)
    }

    private func optionBinding(_ option: TextSearchOptions) -> Binding<Bool> {
        Binding(
            get: { state.options.contains(option) },
            set: { isOn in
                if isOn {
                    state.options.insert(option)
                } else {
                    state.options.remove(option)
                }
            }
        )
    }
}

/// Pure wording for the find bar, kept apart from the view for tests.
nonisolated enum FindBarPresentation {
    static func matchSummary(matchCount: Int, currentIndex: Int?) -> String {
        guard matchCount > 0 else { return "No results" }
        return "\((currentIndex ?? 0) + 1) of \(matchCount)"
    }
}

/// User-facing words for the Markdown mode control: one three-segment choice,
/// "Source | Preview | Split". The model case stays `.edit`; only the word
/// shown to the user is "Source".
nonisolated enum MarkdownModePresentation {
    static func title(for mode: MarkdownPresentationMode) -> String {
        switch mode {
        case .edit: "Source"
        case .preview: "Preview"
        case .split: "Split"
        }
    }

    static func tooltip(for mode: MarkdownPresentationMode) -> String {
        switch mode {
        case .edit: "Show Markdown source"
        case .preview: "Show rendered preview"
        case .split: "Show source and preview side by side"
        }
    }
}

private struct MarkdownModeControl: View {
    @Environment(\.rafuTheme) private var theme
    @Binding var mode: MarkdownPresentationMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MarkdownPresentationMode.allCases, id: \.rawValue) { item in
                segment(item)
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

    private func segment(_ item: MarkdownPresentationMode) -> some View {
        let isSelected = item == mode
        return Button {
            mode = item
        } label: {
            Text(MarkdownModePresentation.title(for: item))
                .rafuNoWrapSegmentLabel()
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(
                    isSelected ? theme.palette.textPrimary : theme.palette.textSecondary
                )
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(theme.palette.selection)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(MarkdownModePresentation.tooltip(for: item))
        .accessibilityLabel(MarkdownModePresentation.title(for: item))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
