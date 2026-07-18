import AppKit
import Foundation
import Observation
import RafuCore

enum WorkspaceNavigatorMode: String, CaseIterable, Codable, Sendable {
    case files
    case search
    case sourceControl

    var title: String {
        switch self {
        case .files: "Files"
        case .search: "Search"
        case .sourceControl: "Source Control"
        }
    }

    var symbolName: String {
        switch self {
        case .files: "doc.on.doc"
        case .search: "magnifyingglass"
        case .sourceControl: "arrow.triangle.branch"
        }
    }
}

@Observable
@MainActor
final class WorkspaceSession {
    struct FileCreationRequest {
        let parentURL: URL
        let isDirectory: Bool
    }

    var descriptor: WorkspaceDescriptor?
    var navigatorMode: WorkspaceNavigatorMode = .files {
        didSet { persistWorkspaceState() }
    }
    /// One materialized directory level per key, keyed by workspace-relative
    /// path ("" for the root). Populated on demand as the sidebar expands
    /// directories instead of eagerly recursing the whole workspace.
    var loadedChildren: [String: [WorkspaceFileNode]] = [:]
    /// Workspace-relative paths of directories the sidebar currently shows
    /// expanded. Drives which `loadedChildren` entries stay populated and
    /// which materialized directories get re-listed on external changes.
    var expandedDirectories: Set<String> = []
    /// Workspace-relative paths of directories with a listing fetch
    /// in flight, so the sidebar can show a per-row loading state and avoid
    /// duplicate concurrent fetches for the same directory.
    var loadingDirectories: Set<String> = []
    var fileIndexState: WorkspaceFileNameIndex.State = .idle
    /// Bumped every time a file-name index build completes. The command
    /// palette keys its file-mode query task off this so a build that
    /// finishes while the palette is open, or was open before the build
    /// started, is never stuck showing empty results.
    var fileIndexGeneration = 0
    var symbolIndexState: WorkspaceSymbolIndex.State = .idle
    /// Bumped every time a workspace-symbol index build or incremental update
    /// completes. The command palette keys its `#`-mode query task off this,
    /// exactly like `fileIndexGeneration` for file mode.
    var symbolIndexGeneration = 0
    var openDocuments: [EditorDocument] = []
    var editorLayout = EditorLayoutState()
    var selectedDocumentID: UUID?
    var selectedTreePath: String?
    /// The in-flight payload for the current, same-process editor drag (tab
    /// or sidebar file). Only ever read inside a `performDrop` that already
    /// validated the `.rafuEditorDrag` type — never used to decide whether a
    /// drop is acceptable. A stale value from a cancelled drag is harmless:
    /// every new drag overwrites it and every completed drop clears it.
    @ObservationIgnored
    var activeEditorDrag: EditorDragPayload?
    var pendingCloseDocument: EditorDocument?
    var pendingFileCreation: FileCreationRequest?
    var pendingFileName = ""
    var gitSnapshot: GitSnapshot? {
        didSet { rebuildGitTreeBadges() }
    }
    /// File-tree Git decorations keyed by workspace-relative path, rebuilt from
    /// `gitSnapshot` whenever it changes so tree rows never recompute the map
    /// per render. Empty when there is no repository or no changes.
    private(set) var gitTreeBadges: [String: GitTreeBadge] = [:]
    var gitSelectedChangeIDs: Set<String> = []
    var gitBranchSnapshot: GitBranchSnapshot?
    var gitHistoryPage: GitHistoryPage?
    var gitSelectedHistoryCommitID: String?
    var gitHistoryCommitChanges: [GitCommitFileChange] = []
    var isGitHistoryDetailLoading = false
    var gitInspectorSection: GitInspectorSection = .changes
    var gitOpenDiff: GitOpenDiff?
    var gitMergeState: GitMergeState?
    var gitStashes: [GitStashEntry] = []
    var gitOpenBlame: GitBlame?
    var gitCommitMessage = ""
    var isGeneratingAICommitMessage = false
    var aiCommitGenerationError: String?
    var isLoadingTree = false
    var isGitBusy = false
    var isGitHunkActionBusy = false
    var isOpenFolderImporterPresented = false
    var isCommandPalettePresented = false
    var commandPaletteSeed = ""
    var isDocumentFindPresented = false
    var isDocumentReplacePresented = false
    var isQuitConfirmationPresented = false
    var isResourcesPresented = false
    /// `true` while `NavigationPeekView` is presented — either a genuine
    /// multi-candidate peek, an in-progress index build, or a "nothing
    /// found" message. `navigate(kind:)` and `navigateToSymbolCandidate(_:)`
    /// are the only writers of this pair; see their doc comments.
    var isNavigationPeekPresented = false
    var navigationPeekContent: NavigationPeekContent?
    var cliInstallMessage: String?
    var isOpenFolderErrorPresented = false
    var openFolderErrorTitle = "Unable to Open Folder"
    var openFolderErrorMessage = ""

    let workspaceSearch = WorkspaceSearchModel()

    @ObservationIgnored
    private var documentFindStates: [UUID: DocumentFindState] = [:]

    @ObservationIgnored
    private var securityScopedURL: URL?

    @ObservationIgnored
    private let fileService = WorkspaceFileService()

    @ObservationIgnored
    private let fileIndex = WorkspaceFileNameIndex()

    @ObservationIgnored
    private var indexRebuildTask: Task<Void, Never>?

    @ObservationIgnored
    private var indexRebuildQueued = false

    @ObservationIgnored
    private let symbolIndex = WorkspaceSymbolIndex()

    @ObservationIgnored
    private var symbolIndexRebuildTask: Task<Void, Never>?

    @ObservationIgnored
    private var symbolIndexRebuildQueued = false

    /// The navigation ladder for the open workspace: syntactic tier over the
    /// symbol index, then the bounded text-search fallback. Rebuilt whenever a
    /// workspace opens (a fresh `rootURL`). The editor-cursor seam that RUNS
    /// this ladder arrives in increment 10b; 10a only owns and constructs it.
    @ObservationIgnored
    private(set) var navigationLadder: NavigationLadder?

    /// The in-flight `navigate(kind:)` request. A second navigation call
    /// cancels this before starting its own — e.g. Go to Definition fired
    /// twice in a row, or the caret moving to a different identifier before
    /// a slow text-tier lookup finishes — so a superseded answer can never
    /// land after a newer one.
    @ObservationIgnored
    private var navigationTask: Task<Void, Never>?

    @ObservationIgnored
    private let gitService = GitService()

    @ObservationIgnored
    private let aiConfigurationStore = UserDefaultsAIProviderConfigurationStore()

    @ObservationIgnored
    private let aiSecretStore = KeychainAISecretStore()

    @ObservationIgnored
    private let aiProviderClient = AIProviderClient()

    @ObservationIgnored
    private let restorationStore = WorkspaceRestorationStore()

    @ObservationIgnored
    private let cliInstaller = CLIInstaller()

    @ObservationIgnored
    private var restorationTask: Task<Void, Never>?

    @ObservationIgnored
    private let liveness = WorkspaceLivenessService()

    /// Lane 2's only access into this session: workspace/document lifecycle
    /// hooks (see `LanguageIntelligenceCoordinator`'s doc comment). Lane 2
    /// never edits this file directly.
    @ObservationIgnored
    let languageIntelligence = LanguageIntelligenceCoordinator()

    func toggleUtilityPane(_ mode: WorkspaceNavigatorMode) {
        navigatorMode = navigatorMode == mode ? .files : mode
    }

    var isTerminalPresented = false

    @ObservationIgnored
    let terminal = WorkspaceTerminalManager()

    func toggleTerminal() {
        isTerminalPresented.toggle()
    }

    /// Opens a new terminal tab starting in the active file's directory,
    /// falling back to the workspace root, then the user's home.
    func newTerminalTab() {
        isTerminalPresented = true
        terminal.newSession(startingDirectory: preferredTerminalDirectory())
    }

    private func preferredTerminalDirectory() -> String {
        if let documentDirectory = selectedDocument?.url.deletingLastPathComponent() {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(
                atPath: documentDirectory.path, isDirectory: &isDirectory
            ), isDirectory.boolValue {
                return documentDirectory.path
            }
        }
        return rootURL?.path ?? NSHomeDirectory()
    }

    var rootURL: URL? {
        guard case .local(let reference) = descriptor?.location else { return nil }
        return URL(fileURLWithPath: reference.path, isDirectory: true)
    }

    var selectedDocument: EditorDocument? {
        openDocuments.first { $0.id == selectedDocumentID }
    }

    /// Ids of documents whose editor is currently visible: the selected tab
    /// of every group across the split layout. Drives the "never hibernate a
    /// visible document" rule in `DocumentHibernationPolicy`.
    var visibleDocumentIDs: Set<UUID> {
        var ids = Set<UUID>()
        for groupID in editorLayout.groupIDs {
            guard let group = editorLayout.group(id: groupID),
                let selectedTabID = group.selectedTabID,
                let tab = group.tabs.first(where: { $0.id == selectedTabID }),
                let document = document(for: tab)
            else { continue }
            ids.insert(document.id)
        }
        return ids
    }

    /// Monotonic access counter feeding each document's `accessSequence`.
    @ObservationIgnored
    private var accessSequenceCounter = 0

    /// Assigns the next access rank to a document as it becomes selected, so
    /// the newest-N grace in `DocumentHibernationPolicy` reflects real use.
    private func recordAccess(_ document: EditorDocument) {
        accessSequenceCounter += 1
        document.accessSequence = accessSequenceCounter
    }

    /// Recomputes the bounded editor working set and flips each open
    /// document's `loadState`. Called from every path that changes document
    /// visibility or the open-document set. Passes `bypassNewestGrace` (the
    /// policy's `underMemoryPressure`) through as `false` by default; the
    /// memory-pressure source arrives in a later increment. `true` drops the
    /// newest-N grace so only the currently visible documents stay loaded —
    /// used by `applyRestoredHibernationPlaceholders()`.
    private func updateHibernationStates(bypassNewestGrace: Bool = false) {
        let visibleIDs = visibleDocumentIDs
        let inputs = openDocuments.map { document in
            DocumentHibernationInput(
                id: document.id,
                isVisible: visibleIDs.contains(document.id),
                isDirty: document.isDirty,
                accessSequence: document.accessSequence
            )
        }
        let hibernating = DocumentHibernationPolicy.hibernating(
            documents: inputs, underMemoryPressure: bypassNewestGrace)
        for document in openDocuments {
            if hibernating.contains(document.id) {
                document.markHibernated()
            } else {
                document.markLoaded()
            }
        }
    }

    /// Applied once, at the end of `restoreLastWorkspaceIfAvailable()`. A
    /// just-restored, never-focused tab is a placeholder, not a loaded
    /// editor: only each group's visible tab should read its file and mount
    /// an `NSTextView` at launch. Every other clean restored document starts
    /// `.hibernated` and materializes through the normal hibernated→refocus
    /// reload path (see `DocumentHibernationPolicy`) the first time the user
    /// selects it. Reuses the memory-pressure branch of
    /// `updateHibernationStates`, which already drops the newest-N grace and
    /// hibernates every non-visible, non-dirty document — exactly the
    /// restoration-placeholder rule, and safe because that branch never
    /// touches a dirty or visible document.
    func applyRestoredHibernationPlaceholders() {
        updateHibernationStates(bypassNewestGrace: true)
    }

    /// Invoked by `MemoryPressureMonitor` on macOS warning/critical memory
    /// pressure. Hibernates every eligible open document immediately (grace
    /// bypassed — reuses the exact policy branch
    /// `applyRestoredHibernationPlaceholders()` uses) and sheds this
    /// session's largest cache outside open documents, the background
    /// filename index. Never touches a dirty or visible document; see
    /// `DocumentHibernationPolicy`.
    ///
    /// The shed index is not rebuilt here — a rebuild-on-demand happens the
    /// next time the command palette actually queries files
    /// (`ensureFileIndexReady()`), so sustained pressure never triggers a
    /// rebuild storm on its own.
    func respondToMemoryPressure() {
        updateHibernationStates(bypassNewestGrace: true)

        indexRebuildTask?.cancel()
        indexRebuildTask = nil
        indexRebuildQueued = false
        fileIndexState = .idle
        Task { await fileIndex.shed() }
        // Bumped even though the shed above is a fire-and-forget actor call:
        // it always wins the race against a later `requestFileIndexRebuild`
        // enqueued from `ensureFileIndexReady`, because actor calls on
        // `fileIndex` execute in submission order.
        fileIndexGeneration += 1

        // Shed the workspace-symbol index alongside the filename index: it is
        // this session's other large cache outside open documents. Same
        // rebuild-on-demand contract — `ensureSymbolIndexReady()` rebuilds it
        // the next time the palette's `#` mode queries, so sustained pressure
        // never triggers a rebuild storm on its own.
        symbolIndexRebuildTask?.cancel()
        symbolIndexRebuildTask = nil
        symbolIndexRebuildQueued = false
        symbolIndexState = .idle
        Task { await symbolIndex.shed() }
        symbolIndexGeneration += 1
    }

    var aiCommitGenerationScopeDescription: String {
        if !gitSelectedChangeIDs.isEmpty {
            let count = gitSelectedChangeIDs.count
            return "\(count) selected \(count == 1 ? "file" : "files")"
                + largeChangesetSuffix(count: count)
        }
        if let staged = gitSnapshot?.stagedChanges, !staged.isEmpty {
            let count = staged.count
            return "\(count) staged \(count == 1 ? "file" : "files")"
                + largeChangesetSuffix(count: count)
        }
        let count = gitSnapshot?.changes.count ?? 0
        return "all \(count) changed \(count == 1 ? "file" : "files")"
            + largeChangesetSuffix(count: count)
    }

    /// Count-based heuristic only. A changeset above `maximumFullDiffCount`
    /// always has some files summarized; the per-file/total-byte budget can
    /// trim further even under that count (many small files, or a few huge
    /// ones), but that byte-driven case isn't cheap to predict per keystroke,
    /// so it's disclosed in the prompt instruction instead of this caption.
    private func largeChangesetSuffix(count: Int) -> String {
        guard count > AICommitPromptBuilder.maximumFullDiffCount else { return "" }
        return " — large changeset, some diffs summarized"
    }

    var canGenerateAICommitMessage: Bool {
        !isGeneratingAICommitMessage && gitSnapshot?.changes.isEmpty == false
    }

    var windowTitle: String {
        if selectedDocumentID == nil, let gitOpenDiff {
            return
                "\(gitOpenDiff.title) — \(descriptor?.displayName ?? RafuBuildInformation.appName)"
        }
        if let selectedDocument {
            return
                "\(selectedDocument.displayName) — \(descriptor?.displayName ?? RafuBuildInformation.appName)"
        }
        return descriptor?.displayName ?? RafuBuildInformation.appName
    }

    func requestOpenFolder() {
        isOpenFolderImporterPresented = true
    }

    func openLocalWorkspace(at url: URL) {
        // URLs from the file importer or bookmarks carry a security scope;
        // URLs from the rafu CLI / Finder open events do not. Without a
        // scope, plain readability is sufficient (and all this build can
        // rely on outside the sandbox).
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        if !hasSecurityScope {
            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                isDirectory.boolValue,
                FileManager.default.isReadableFile(atPath: url.path)
            else {
                reportOpenFolderError(WorkspaceOpenError.securityScopedAccessDenied)
                return
            }
        }

        liveness.stop()
        let previousSecurityScopedURL = securityScopedURL
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent

        securityScopedURL = hasSecurityScope ? url : nil
        descriptor = WorkspaceDescriptor(
            displayName: name,
            location: .local(LocalWorkspaceReference(path: url.path))
        )
        navigationLadder = makeNavigationLadder(rootURL: url)
        openDocuments = []
        editorLayout = EditorLayoutState()
        documentFindStates = [:]
        workspaceSearch.reset()
        workspaceSearch.loadHistory(for: url)
        selectedDocumentID = nil
        selectedTreePath = nil
        resetGitWorkbenchState()
        resetFileTreeState()
        isTerminalPresented = false
        terminal.shutdownAll()
        languageIntelligence.workspaceDidClose()
        RecentWorkspacesStore().record(url: url, displayName: name)
        Task { await refreshWorkspace() }
        startFileWatcher()
        languageIntelligence.workspaceDidOpen(root: url)
        persistWorkspaceState()

        previousSecurityScopedURL?.stopAccessingSecurityScopedResource()
    }

    /// Starts (or restarts) the FSEvents watcher on the current root so
    /// external file and Git changes refresh the tree, clean buffers, and
    /// Source Control without an in-app mutation.
    private func startFileWatcher() {
        guard let rootURL else { return }
        liveness.start(rootURL: rootURL) { [weak self] in
            guard let self else { return [] }
            return Set(
                openDocuments.map {
                    $0.url.resolvingSymlinksInPath().standardizedFileURL.path
                }
            )
        } onChanges: { [weak self] changes in
            await self?.handleExternalChanges(changes)
        }
    }

    private func handleExternalChanges(_ changes: WorkspaceChangeSet) async {
        if changes.isStorm {
            // A large debounced batch (branch checkout, npm install, mass
            // touch) collapses into one coalesced full refresh instead of
            // per-changed-directory work, which already includes the git
            // snapshot and a single index rebuild.
            await refreshWorkspace()
        } else if changes.treeChanged {
            // A working-tree edit (no `.git/HEAD` or `.git/index` touch)
            // still changes `git status`, so the lightweight snapshot
            // refreshes alongside every tree change, not only `gitChanged`
            // ones (which drive the heavier branch/history/merge refresh).
            async let directories: Void = refreshChangedDirectories(
                changes.changedDirectoryRelativePaths)
            async let gitSnapshotRefresh: Void = refreshGitSnapshotOnly()
            _ = await (directories, gitSnapshotRefresh)
            requestFileIndexRebuild()
            requestSymbolIndexIncrementalUpdate(
                changedDirectoryRelativePaths: changes.changedDirectoryRelativePaths)
        }
        if changes.gitChanged { await refreshGit() }
        guard !changes.changedDocumentPaths.isEmpty else { return }
        for document in openDocuments where !document.isDirty {
            let path = document.url.resolvingSymlinksInPath().standardizedFileURL.path
            guard changes.changedDocumentPaths.contains(path) else { continue }
            let diskDate =
                (try? FileManager.default.attributesOfItem(atPath: document.url.path))?[
                    .modificationDate] as? Date
            // Belt and braces beside kFSEventStreamCreateFlagIgnoreSelf: a
            // reload wipes undo history, so skip when the file on disk still
            // matches what Rafu last loaded or saved.
            if let known = document.knownDiskModificationDate, let diskDate, known == diskDate {
                continue
            }
            document.revision += 1
        }
    }

    /// Re-lists the workspace root plus every directory the sidebar has
    /// already materialized (rename, create, checkout, pull, merge,
    /// replacement, restore, and the initial open all funnel through here).
    /// Bounded by expansion: a directory the sidebar has never opened is
    /// never listed, matching `loadChildrenIfNeeded`.
    func refreshWorkspace() async {
        guard let rootURL else { return }
        isLoadingTree = true
        // The early cancellation return must still clear the loading flag or
        // the sidebar shows "Loading files…" forever after a superseded
        // refresh (e.g. rapid branch switches).
        defer { isLoadingTree = false }
        do {
            async let tree: Void = reloadMaterializedDirectories(rootURL: rootURL)
            async let git = gitService.snapshot(at: rootURL)
            try await tree
            gitSnapshot = try await git
            if gitSnapshot == nil { resetGitWorkbenchState() }
            reconcileGitSelection()
            requestFileIndexRebuild()
            requestSymbolIndexRebuild()
        } catch is CancellationError {
            return
        } catch {
            reportOpenFolderError(error)
        }
    }

    /// Loads one directory level on demand — called when the sidebar
    /// expands a directory that has not been materialized yet. A no-op if
    /// the directory is already loaded or a fetch for it is in flight.
    func loadChildrenIfNeeded(_ relativeDirectoryPath: String) {
        guard loadedChildren[relativeDirectoryPath] == nil,
            !loadingDirectories.contains(relativeDirectoryPath)
        else { return }
        Task { await loadChildren(relativeDirectoryPath) }
    }

    /// Expands and loads every ancestor directory of `path` (workspace root
    /// or a folder breadcrumb segment, always a directory) so the sidebar
    /// shows it. Scrolling the row into view is deferred future work.
    func revealInSidebar(path: String) {
        selectedTreePath = path
        guard let rootURL else { return }
        let rootPath = rootURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return }
        let relative = String(path.dropFirst(rootPath.count)).trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        let components = relative.isEmpty ? [] : relative.split(separator: "/").map(String.init)
        Task { await expandAndLoadAncestors(components) }
    }

    /// Opens a file at a workspace-relative path — used by the command
    /// palette, which resolves file mode against the background name index
    /// rather than the sidebar's materialized tree.
    func openFile(atRelativePath relativePath: String) {
        guard let rootURL else { return }
        let url = rootURL.appending(path: relativePath)
        open(WorkspaceFileNode(url: url, relativePath: relativePath, isDirectory: false))
    }

    /// Opens the file at a workspace-relative path and selects `range` — the
    /// command palette's `#` workspace-symbol jump. Mirrors `openFile` plus a
    /// find-state range selection, without touching the workspace-search find
    /// query the way `openSearchLocation` does.
    func openWorkspaceSymbol(relativePath: String, range: NSRange) {
        guard let rootURL else { return }
        let url = rootURL.appending(path: relativePath)
        let document: EditorDocument
        if let existing = openDocuments.first(where: { $0.url == url }) {
            document = existing
        } else {
            document = trackNewDocument(url: url)
        }
        select(document)
        findState(for: document).select(range)
    }

    /// Opens a file at a workspace-relative path and selects the location
    /// described by `location` — the CLI `--goto` entry point
    /// (`Sources/RafuCore/Launcher/IPC/**`; contract signature landed by
    /// I0, see `docs/plans/phases/cli-app-ipc.md`). Mirrors
    /// `openWorkspaceSymbol`'s open/select shape, computing the UTF-16
    /// selection range from the file's on-disk contents via
    /// `LineColumnIndex`. Reusing `DocumentFindState.select(_:)` means a
    /// buffer that isn't mounted yet still receives the pending selection
    /// once it is (`DocumentFindState.attach(_:)`); a dirty in-memory
    /// buffer's live text and exact-column precision on a hibernated tab
    /// are completed by the IPC lane's I4 increment — this is an honest
    /// best-effort selection, not the final behavior.
    func openFile(atRelativePath relativePath: String, selecting location: SourceLocation) {
        guard let rootURL else { return }
        let url = rootURL.appending(path: relativePath)
        let document: EditorDocument
        if let existing = openDocuments.first(where: { $0.url == url }) {
            document = existing
        } else {
            document = trackNewDocument(url: url)
        }
        let liveText = document.textSnapshotProvider?()
        let text = liveText ?? (try? String(contentsOf: url, encoding: .utf8))
        let range = text.map {
            NSRange(
                location: LineColumnIndex.utf16Offset(
                    line: location.line, column: location.column, in: $0),
                length: 0
            )
        }
        if liveText == nil, let range {
            document.captureViewState(selection: range, scrollFraction: nil)
        }
        select(document)
        if let range { findState(for: document).select(range) }
    }

    /// Caret-driven navigation entry point for the "Go to Definition"/"Go to
    /// Declaration"/"Find References" menu commands. Builds a
    /// `NavigationRequest` from the active editor's caret and identifier,
    /// runs it through `navigationLadder`, and either jumps straight to a
    /// sole candidate or presents a peek. A no-op when there is no selected
    /// document, its editor is not mounted (hibernated/preview-only), or no
    /// workspace is open — all three leave the UI exactly as it was.
    func navigate(kind: NavigationTargetKind) {
        guard let document = selectedDocument,
            let snapshotProvider = document.textSnapshotProvider,
            let selectionProvider = document.selectionProvider,
            let ladder = navigationLadder
        else { return }

        let selection = selectionProvider()
        guard
            let identifier = IdentifierUnderCaret.word(
                in: snapshotProvider(), at: selection.location)
        else {
            presentNavigationPeek(.empty(kind))
            return
        }

        let languageID = resolveLanguageID(for: document.url)
        let request = NavigationRequest(
            documentURL: document.url,
            position: identifier.position,
            languageID: languageID,
            kind: kind,
            symbolName: identifier.word
        )

        // The syntactic tier reads the workspace-symbol index; make sure an
        // idle (e.g. memory-pressure-shed) index rebuilds before resolving,
        // exactly like the command palette's `#` mode.
        ensureSymbolIndexReady()

        navigationTask?.cancel()
        navigationTask = Task(name: "Navigate \(kind)") { [weak self] in
            guard let self else { return }
            let answer = try? await ladder.resolve(request)
            if Task.isCancelled { return }
            switch NavigationPresentation.outcome(for: answer, kind: kind) {
            case .jump(let candidate):
                navigateToSymbolCandidate(candidate)
            case .peek(let content):
                presentNavigationPeek(content)
            }
        }
    }

    /// The LSP tier is the only consumer of `languageID`, so this returns
    /// lane 2's canonical LSP id (`.tsx` → "typescriptreact", `.rs` → "rust",
    /// …) so a request keys to the same server the coordinator opened the
    /// document under. The syntactic/text tiers ignore this field (they key
    /// off `symbolName`); the grammar id / extension is a harmless fallback
    /// for an extension no language server recognizes. Shared by
    /// `navigate(kind:)` and `hoverInfo(at:utf16Offset:)`.
    private func resolveLanguageID(for url: URL) -> String {
        LanguageIdentifier.forURL(url)
            ?? GrammarLanguageID.languageID(
                forExtension: url.pathExtension.lowercased(),
                fileName: url.lastPathComponent
            )?.rawValue ?? url.pathExtension.lowercased()
    }

    /// Resolves an LSP hover for the identifier at `utf16Offset` in the active
    /// document, for the editor's hover tooltip. Deliberately LSP-only: it
    /// runs the same `NavigationLadder` with a `.hover` request, but the
    /// syntactic and text tiers both decline `.hover`, so a language with no
    /// live, trusted server yields `nil` and the caller shows no tooltip.
    ///
    /// Unlike `navigate(kind:)` this is a pure, side-effect-free read: it does
    /// NOT cancel `navigationTask`, does NOT rebuild the symbol index, and
    /// never touches peek state or the caret — hovering must never move the
    /// user or disturb an in-flight explicit navigation. Returns `nil` when
    /// there is no mounted active document, the hovered offset is not on an
    /// identifier, or every tier declines. The returned hover text is a
    /// redaction-sensitive server payload and is never logged.
    func hoverInfo(at documentURL: URL, utf16Offset: Int) async -> EditorHoverInfo? {
        guard let document = selectedDocument,
            document.url == documentURL,
            let snapshotProvider = document.textSnapshotProvider,
            let ladder = navigationLadder
        else { return nil }

        let snapshot = snapshotProvider()
        // Nil-tolerant: the LSP resolves hover by position, so a missing
        // identifier (e.g. hovering an operator) still lets the server answer;
        // the name is carried only for the tooltip's accessibility label.
        let symbolName = IdentifierUnderCaret.word(in: snapshot, at: utf16Offset)?.word
        let request = NavigationRequest(
            documentURL: document.url,
            position: utf16Offset,
            languageID: resolveLanguageID(for: document.url),
            kind: .hover,
            symbolName: symbolName
        )
        let answer = try? await ladder.resolve(request)
        guard let text = answer?.candidates.first?.previewLine, !text.isEmpty else { return nil }
        // The LSP hover contract doesn't carry the server's `MarkupContent.kind`
        // this far (see `LSPNavigationProvider.flattenedHoverMultiline`), so the
        // tooltip renderer always treats the flattened text as Markdown — the
        // common case for language servers, and harmless for a plaintext hover
        // (no fences to find, so it falls through to plain documentation).
        let parsed = HoverMarkdownParser.parse(text, isMarkdown: true)
        return EditorHoverInfo(
            text: text,
            symbolName: symbolName,
            signature: parsed.signature,
            documentation: parsed.documentation,
            isMarkdown: true
        )
    }

    /// Jumps straight to a resolved navigation candidate — used both for a
    /// single-candidate `navigate(kind:)` outcome and for a row selected from
    /// `NavigationPeekView`. Dismisses the peek (a no-op if it was never
    /// presented) before opening, mirroring `openWorkspaceSymbol`'s jump.
    func navigateToSymbolCandidate(_ candidate: SymbolCandidate) {
        isNavigationPeekPresented = false
        openWorkspaceSymbol(relativePath: candidate.relativePath, range: candidate.range)
    }

    private func presentNavigationPeek(_ content: NavigationPeekContent) {
        navigationPeekContent = content
        isNavigationPeekPresented = true
    }

    /// Ranks the background file-name index against `term`, off-main and
    /// cancellable. An empty term returns the first `limit` indexed paths.
    func queryFileIndex(term: String, limit: Int) async throws -> [String] {
        try await fileIndex.query(term: term, limit: limit)
    }

    /// Idempotent rebuild trigger for an idle file-name index — a no-op
    /// unless there is a workspace root, the index is `.idle`, and no
    /// rebuild is already in flight. Called before every command-palette
    /// file query so an index a memory-pressure shed emptied transparently
    /// rebuilds the moment the palette needs it again, without a background
    /// poll or an extra timer. `requestFileIndexRebuild()` flips
    /// `fileIndexState` to `.building` synchronously, before this returns, so
    /// the palette's idle-state message never flashes "Open a folder" first.
    func ensureFileIndexReady() {
        guard rootURL != nil, fileIndexState == .idle, indexRebuildTask == nil else { return }
        requestFileIndexRebuild()
    }

    /// Ranks the background workspace-symbol index against `term`, off-main
    /// and cancellable. An empty term returns the first `limit` symbols.
    func queryWorkspaceSymbols(term: String, limit: Int) async throws -> [WorkspaceSymbolMatch] {
        try await symbolIndex.query(term: term, limit: limit)
    }

    /// Symbol-index counterpart to `ensureFileIndexReady()`: rebuilds an idle
    /// index (e.g. one a memory-pressure shed emptied) the moment the
    /// palette's `#` mode needs it again, with no background poll or timer.
    func ensureSymbolIndexReady() {
        guard rootURL != nil, symbolIndexState == .idle, symbolIndexRebuildTask == nil else {
            return
        }
        requestSymbolIndexRebuild()
    }

    /// Constructs the navigation ladder for `rootURL`. The syntactic tier sits
    /// above the bounded text tier.
    private func makeNavigationLadder(rootURL: URL) -> NavigationLadder {
        let coordinator = languageIntelligence
        return NavigationLadder(providers: [
            // LSP tier (lane 2): a trusted, running language server answers
            // first, labeled "via <server>". It declines — falling through to
            // the syntactic then text tiers — when no server is installed or
            // trusted for the language, or a request fails/times out.
            LSPNavigationProvider(rootURL: rootURL) { languageID in
                await coordinator.session(forLanguageID: languageID)
            },
            SyntacticNavigationProvider(index: symbolIndex, rootURL: rootURL),
            TextSearchNavigationProvider(rootURL: rootURL),
        ])
    }

    private func expandAndLoadAncestors(_ components: [String]) async {
        expandedDirectories.insert("")
        await loadChildren("")
        var currentRelativePath = ""
        for component in components {
            currentRelativePath =
                currentRelativePath.isEmpty ? component : currentRelativePath + "/" + component
            expandedDirectories.insert(currentRelativePath)
            await loadChildren(currentRelativePath)
        }
    }

    private func loadChildren(_ relativeDirectoryPath: String) async {
        guard let rootURL, loadedChildren[relativeDirectoryPath] == nil else { return }
        guard !loadingDirectories.contains(relativeDirectoryPath) else { return }
        loadingDirectories.insert(relativeDirectoryPath)
        defer { loadingDirectories.remove(relativeDirectoryPath) }
        do {
            let children = try await fileService.listDirectory(
                rootURL: rootURL, relativeDirectoryPath: relativeDirectoryPath)
            loadedChildren[relativeDirectoryPath] = children
        } catch is CancellationError {
            return
        } catch {
            reportOpenFolderError(error)
        }
    }

    private func reloadMaterializedDirectories(rootURL: URL) async throws {
        var relativePaths = Set(loadedChildren.keys)
        relativePaths.insert("")
        var updated: [String: [WorkspaceFileNode]] = [:]
        for relativePath in relativePaths {
            try Task.checkCancellation()
            if let children = try? await fileService.listDirectory(
                rootURL: rootURL, relativeDirectoryPath: relativePath)
            {
                updated[relativePath] = children
            }
        }
        loadedChildren = updated
        expandedDirectories.formIntersection(Set(updated.keys))
    }

    /// FSEvents path: re-lists only the changed directories the sidebar has
    /// already materialized, pruning a directory (and every materialized
    /// descendant, by relative-path prefix) that no longer lists.
    private func refreshChangedDirectories(_ changedDirectoryRelativePaths: Set<String>) async {
        guard let rootURL else { return }
        let materializedChanged = changedDirectoryRelativePaths.filter {
            loadedChildren[$0] != nil
        }
        for relativePath in materializedChanged {
            do {
                let children = try await fileService.listDirectory(
                    rootURL: rootURL, relativeDirectoryPath: relativePath)
                loadedChildren[relativePath] = children
            } catch is CancellationError {
                return
            } catch {
                pruneMaterializedSubtree(rootedAt: relativePath)
            }
        }
    }

    private func pruneMaterializedSubtree(rootedAt relativePath: String) {
        let prefix = relativePath.isEmpty ? nil : relativePath + "/"
        loadedChildren = loadedChildren.filter { key, _ in
            key != relativePath && !(prefix.map(key.hasPrefix) ?? false)
        }
        expandedDirectories = expandedDirectories.filter { key in
            key != relativePath && !(prefix.map(key.hasPrefix) ?? false)
        }
    }

    private func refreshGitSnapshotOnly() async {
        guard let rootURL else { return }
        do {
            gitSnapshot = try await gitService.snapshot(at: rootURL)
            if gitSnapshot == nil { resetGitWorkbenchState() }
            reconcileGitSelection()
        } catch is CancellationError {
            return
        } catch {
            reportOpenFolderError(error)
        }
    }

    private func resetFileTreeState() {
        loadedChildren = [:]
        expandedDirectories = []
        loadingDirectories = []
        navigationTask?.cancel()
        navigationTask = nil
        isNavigationPeekPresented = false
        navigationPeekContent = nil
        indexRebuildTask?.cancel()
        indexRebuildTask = nil
        indexRebuildQueued = false
        fileIndexState = .idle
        Task { await fileIndex.reset() }
        symbolIndexRebuildTask?.cancel()
        symbolIndexRebuildTask = nil
        symbolIndexRebuildQueued = false
        symbolIndexState = .idle
        Task { await symbolIndex.reset() }
    }

    /// Coalesces index rebuild requests to one build in flight plus at most
    /// one trailing rebuild, so FSEvents storms and back-to-back Git
    /// operations never pile up overlapping `git ls-files`/enumerator work.
    private func requestFileIndexRebuild() {
        guard let rootURL else { return }
        if indexRebuildTask != nil {
            indexRebuildQueued = true
            return
        }
        fileIndexState = .building
        indexRebuildTask = Task(name: "Rebuild file name index") { [weak self] in
            guard let self else { return }
            await fileIndex.build(rootURL: rootURL)
            fileIndexState = await fileIndex.currentState
            fileIndexGeneration += 1
            indexRebuildTask = nil
            if indexRebuildQueued {
                indexRebuildQueued = false
                requestFileIndexRebuild()
            }
        }
    }

    /// Full workspace-symbol rebuild, coalescing exactly like
    /// `requestFileIndexRebuild()`: one build in flight plus at most one
    /// trailing rebuild, so FSEvents storms and back-to-back Git operations
    /// never pile up overlapping parses.
    private func requestSymbolIndexRebuild() {
        guard let rootURL else { return }
        if symbolIndexRebuildTask != nil {
            symbolIndexRebuildQueued = true
            return
        }
        symbolIndexState = .building
        symbolIndexRebuildTask = Task(name: "Rebuild workspace symbol index") { [weak self] in
            guard let self else { return }
            await symbolIndex.build(rootURL: rootURL)
            symbolIndexState = await symbolIndex.currentState
            symbolIndexGeneration += 1
            symbolIndexRebuildTask = nil
            if symbolIndexRebuildQueued {
                symbolIndexRebuildQueued = false
                requestSymbolIndexRebuild()
            }
        }
    }

    /// Incrementally patches the symbol index for a non-storm working-tree
    /// change. When a (re)build is already in flight, it queues a trailing
    /// full rebuild rather than racing a patch against it; when the index is
    /// not yet `.ready` (never built or shed), it requests a full build, which
    /// is the correct response and is coalesced.
    private func requestSymbolIndexIncrementalUpdate(
        changedDirectoryRelativePaths dirs: Set<String>
    ) {
        guard let rootURL else { return }
        if symbolIndexRebuildTask != nil {
            symbolIndexRebuildQueued = true
            return
        }
        guard case .ready = symbolIndexState else {
            requestSymbolIndexRebuild()
            return
        }
        symbolIndexRebuildTask = Task(name: "Update workspace symbol index") { [weak self] in
            guard let self else { return }
            await symbolIndex.applyChanges(
                changedDirectoryRelativePaths: dirs, rootURL: rootURL)
            symbolIndexState = await symbolIndex.currentState
            symbolIndexGeneration += 1
            symbolIndexRebuildTask = nil
            if symbolIndexRebuildQueued {
                symbolIndexRebuildQueued = false
                requestSymbolIndexRebuild()
            }
        }
    }

    func refreshGit() async {
        guard let rootURL else { return }
        do {
            guard let snapshot = try await gitService.snapshot(at: rootURL) else {
                resetGitWorkbenchState()
                return
            }
            async let branches = gitService.branches(at: rootURL)
            async let history = gitService.history(at: rootURL, limit: 100)
            async let merge = gitService.mergeState(at: rootURL)
            gitSnapshot = snapshot
            gitBranchSnapshot = try await branches
            gitHistoryPage = try await history
            let previousMergeState = gitMergeState
            gitMergeState = (try? await merge) ?? nil
            // Prefill the commit box with git's default merge message the
            // moment a merge is first detected — but never stomp user edits.
            if let mergeState = gitMergeState,
                previousMergeState == nil,
                gitCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                gitCommitMessage = mergeState.defaultMessage
            }
            reconcileGitSelection()
        } catch {
            reportGitError(error)
        }
    }

    func open(_ node: WorkspaceFileNode) {
        guard !node.isDirectory else { return }
        if let existing = openDocuments.first(where: { $0.url == node.url }) {
            select(existing)
            return
        }
        let document = trackNewDocument(url: node.url)
        select(document)
    }

    /// Creates and registers a brand-new `EditorDocument`: appends it to
    /// `openDocuments`, seeds its find state, and notifies
    /// `languageIntelligence`. Every document-creation site in this file
    /// routes through here so lane 2 always learns about a new document,
    /// regardless of which UI path opened it.
    private func trackNewDocument(url: URL) -> EditorDocument {
        let document = EditorDocument(url: url)
        openDocuments.append(document)
        documentFindStates[document.id] = DocumentFindState()
        languageIntelligence.documentDidOpen(document)
        return document
    }

    func select(_ document: EditorDocument) {
        let resource = EditorTabResource.file(document.url)
        let tab: EditorTabState
        let groupID: EditorGroupID
        if let existingTab = editorLayout.tab(matching: resource),
            let existingGroup = editorLayout.group(containing: existingTab.id)
        {
            tab = existingTab
            groupID = existingGroup.id
        } else {
            tab = EditorTabState(resource: resource)
            groupID = editorLayout.focusedGroupID
            editorLayout.insert(tab, in: groupID)
        }
        editorLayout.select(tab.id, in: groupID)
        selectedDocumentID = document.id
        selectedTreePath = document.url.path
        recordAccess(document)
        updateHibernationStates()
        persistWorkspaceState()
    }

    func requestClose(_ document: EditorDocument) {
        if document.isDirty {
            pendingCloseDocument = document
        } else {
            close(document)
        }
    }

    func saveAndClosePendingDocument() {
        guard let document = pendingCloseDocument else { return }
        document.saveAction?()
        pendingCloseDocument = nil
        close(document)
    }

    func discardAndClosePendingDocument() {
        guard let document = pendingCloseDocument else { return }
        pendingCloseDocument = nil
        close(document)
    }

    private func close(_ document: EditorDocument) {
        guard let index = openDocuments.firstIndex(where: { $0.id == document.id }) else { return }
        openDocuments.remove(at: index)
        if let tab = editorLayout.tab(matching: .file(document.url)) {
            _ = editorLayout.closeTab(tab.id)
        }
        documentFindStates[document.id] = nil
        languageIntelligence.documentDidClose(document)
        synchronizeSelectionFromLayout(
            fallback: openDocuments.indices.contains(index)
                ? openDocuments[index] : openDocuments.last
        )
        updateHibernationStates()
        persistWorkspaceState()
    }

    func saveSelectedDocument() {
        selectedDocument?.saveAction?()
    }

    func requestCloseActiveTab() {
        if let selectedDocument {
            requestClose(selectedDocument)
            return
        }
        if gitOpenDiff != nil {
            closeGitDiff()
            return
        }
        if UserDefaults.standard.bool(forKey: "quitWithoutEmptyWindowConfirmation") {
            NSApp.terminate(nil)
        } else {
            isQuitConfirmationPresented = true
        }
    }

    func findState(for document: EditorDocument) -> DocumentFindState {
        if let state = documentFindStates[document.id] { return state }
        let state = DocumentFindState()
        documentFindStates[document.id] = state
        return state
    }

    /// Presents the command palette. An empty seed opens file mode;
    /// ">" seeds command mode and "@" seeds symbol mode.
    func showCommandPalette(seed: String = "") {
        commandPaletteSeed = seed
        isCommandPalettePresented = true
    }

    /// Presents the Resources popover (app resident memory plus every
    /// Rafu-spawned process).
    func showResources() {
        isResourcesPresented = true
    }

    func showDocumentFind(includeReplace: Bool = false) {
        guard let selectedDocument else { return }
        isDocumentFindPresented = true
        isDocumentReplacePresented = includeReplace
        findState(for: selectedDocument).activate()
    }

    func dismissDocumentFind() {
        isDocumentFindPresented = false
        isDocumentReplacePresented = false
        for state in documentFindStates.values {
            state.deactivate()
        }
    }

    func toggleLineComment() {
        selectedDocument?.toggleCommentAction?()
    }

    func selectNextOccurrence() {
        selectedDocument?.selectNextOccurrenceAction?()
    }

    func selectAllOccurrences() {
        selectedDocument?.selectAllOccurrencesAction?()
    }

    func addCaretAbove() {
        selectedDocument?.addCaretAboveAction?()
    }

    func addCaretBelow() {
        selectedDocument?.addCaretBelowAction?()
    }

    func selectEditorTab(_ tabID: EditorTabID, in groupID: EditorGroupID) {
        guard let tab = editorLayout.group(id: groupID)?.tabs.first(where: { $0.id == tabID }),
            let document = document(for: tab)
        else { return }
        editorLayout.select(tabID, in: groupID)
        selectedDocumentID = document.id
        selectedTreePath = document.url.path
        recordAccess(document)
        updateHibernationStates()
        persistWorkspaceState()
    }

    func splitEditorTab(_ tabID: EditorTabID, at edge: EditorSplitEdge) {
        guard let groupID = editorLayout.group(containing: tabID)?.id,
            editorLayout.split(group: groupID, at: edge, moving: tabID) != nil
        else { return }
        synchronizeSelectionFromLayout()
        updateHibernationStates()
        persistWorkspaceState()
    }

    func moveEditorTab(_ tabID: EditorTabID, to groupID: EditorGroupID) {
        guard editorLayout.moveTab(tabID, to: groupID) else { return }
        synchronizeSelectionFromLayout()
        updateHibernationStates()
        persistWorkspaceState()
    }

    /// Starts an editor drag (tab or sidebar file): caches the payload for
    /// the same-process fast path and returns an item provider carrying the
    /// pre-encoded payload for the AppKit drag session, which also covers
    /// cross-window drops.
    func beginEditorDrag(_ payload: EditorDragPayload) -> NSItemProvider {
        activeEditorDrag = payload
        return payload.makeItemProvider()
    }

    func clearEditorDrag() {
        activeEditorDrag = nil
    }

    /// Handles a dropped tab. `nil` edge moves the tab into the hovered
    /// group (no-op if it is already there); a non-`nil` edge splits the
    /// hovered group and moves the tab into the new pane.
    func handleEditorTabDrop(_ value: String, on groupID: EditorGroupID, edge: EditorSplitEdge?) {
        guard let uuid = UUID(uuidString: value) else { return }
        let tabID = EditorTabID(rawValue: uuid)
        guard editorLayout.group(containing: tabID) != nil else { return }
        guard let edge else {
            guard editorLayout.group(containing: tabID)?.id != groupID else { return }
            moveEditorTab(tabID, to: groupID)
            return
        }
        if editorLayout.group(containing: tabID)?.id == groupID {
            splitEditorTab(tabID, at: edge)
        } else {
            moveEditorTab(tabID, to: groupID)
            splitEditorTab(tabID, at: edge)
        }
    }

    /// Handles a file dropped from the Files sidebar. Directories are
    /// rejected. If the file already has a tab, this defers to
    /// `handleEditorTabDrop` for identical move/split semantics; otherwise a
    /// new document and tab are created and opened in place (`nil` edge) or
    /// in a freshly split pane (non-`nil` edge), mirroring `select(_:)`.
    func handleEditorFileDrop(path: String, on groupID: EditorGroupID, edge: EditorSplitEdge?) {
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else { return }

        if let existingTab = editorLayout.tab(matching: .file(url)) {
            handleEditorTabDrop(existingTab.id.rawValue.uuidString, on: groupID, edge: edge)
            return
        }

        let document: EditorDocument
        if let existing = openDocuments.first(where: { $0.url == url }) {
            document = existing
        } else {
            document = trackNewDocument(url: url)
        }

        let targetGroupID: EditorGroupID
        if let edge {
            guard let newGroupID = editorLayout.split(group: groupID, at: edge, moving: nil)
            else { return }
            targetGroupID = newGroupID
        } else {
            targetGroupID = groupID
        }

        let tab = EditorTabState(resource: .file(url))
        editorLayout.insert(tab, in: targetGroupID)
        editorLayout.select(tab.id, in: targetGroupID)
        selectedDocumentID = document.id
        selectedTreePath = document.url.path
        recordAccess(document)
        updateHibernationStates()
        persistWorkspaceState()
    }

    func document(for tab: EditorTabState) -> EditorDocument? {
        guard case .file(let url) = tab.resource else { return nil }
        return openDocuments.first { $0.url == url }
    }

    func isFocusedGroup(_ groupID: EditorGroupID) -> Bool {
        editorLayout.focusedGroupID == groupID
    }

    func openSearchMatch(_ group: WorkspaceSearchFileGroup, match: WorkspaceSearchMatch) {
        openSearchLocation(fileURL: group.fileURL, range: match.range)
    }

    func openSearchLocation(fileURL: URL, range: NSRange) {
        let document: EditorDocument
        if let existing = openDocuments.first(where: { $0.url == fileURL }) {
            document = existing
        } else {
            document = trackNewDocument(url: fileURL)
        }
        select(document)
        let state = findState(for: document)
        state.query = workspaceSearch.query
        state.options = workspaceSearch.options
        state.select(range)
    }

    func applyWorkspaceReplacement() async {
        guard let preview = workspaceSearch.replacementPreview else { return }
        let changedURLs = Set(preview.files.map(\.fileURL))
        if let dirty = openDocuments.first(where: { $0.isDirty && changedURLs.contains($0.url) }) {
            workspaceSearch.report(
                "Save or close \(dirty.displayName) before replacing matches in the workspace.")
            return
        }
        do {
            let report = try await workspaceSearch.applyPreview()
            for document in openDocuments where report.changedFiles.contains(document.url) {
                document.revision += 1
            }
            await refreshWorkspace()
            if let rootURL { workspaceSearch.search(in: rootURL) }
        } catch {
            return
        }
    }

    func installCLI() {
        Task(name: "Install rafu CLI") {
            do {
                let result = try await cliInstaller.install()
                cliInstallMessage =
                    "Installed at \(result.installedURL.path)"
                    + (result.pathHint.map { "\n\n\($0)" } ?? "")
            } catch {
                cliInstallMessage = error.localizedDescription
            }
        }
    }

    func rename(_ node: WorkspaceFileNode, to name: String) async {
        do {
            let newURL = try await fileService.rename(node.url, to: name)
            for document in openDocuments {
                if document.url == node.url {
                    if let tab = editorLayout.tab(matching: .file(document.url)) {
                        editorLayout.updateResource(for: tab.id, to: .file(newURL))
                    }
                    document.url = newURL
                } else if node.isDirectory,
                    document.url.path.hasPrefix(node.url.path + "/")
                {
                    let suffix = document.url.path.dropFirst(node.url.path.count)
                    let oldURL = document.url
                    document.url = URL(fileURLWithPath: newURL.path + suffix)
                    if let tab = editorLayout.tab(matching: .file(oldURL)) {
                        editorLayout.updateResource(for: tab.id, to: .file(document.url))
                    }
                }
            }
            await refreshWorkspace()
        } catch { reportOpenFolderError(error) }
    }

    func requestFileCreation(in parentURL: URL? = nil, isDirectory: Bool) {
        guard let directory = parentURL ?? rootURL else { return }
        pendingFileName = ""
        pendingFileCreation = FileCreationRequest(parentURL: directory, isDirectory: isDirectory)
    }

    func createPendingFileItem() async {
        guard let request = pendingFileCreation else { return }
        do {
            let url = try await fileService.createItem(
                in: request.parentURL,
                named: pendingFileName,
                isDirectory: request.isDirectory
            )
            pendingFileCreation = nil
            pendingFileName = ""
            await refreshWorkspace()
            if !request.isDirectory {
                open(
                    WorkspaceFileNode(
                        url: url,
                        relativePath: relativePath(for: url),
                        isDirectory: false
                    )
                )
            }
        } catch {
            reportOpenFolderError(error)
        }
    }

    private func relativePath(for url: URL) -> String {
        guard let rootURL else { return url.lastPathComponent }
        return String(url.path.dropFirst(rootURL.path.count)).trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
    }

    func setStaged(_ staged: Bool, change: GitChange) async {
        guard let rootURL else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            try await gitService.setStaged(staged, path: change.path, at: rootURL)
            await refreshGit()
        } catch { reportGitError(error) }
    }

    /// Batch stage/unstage in one Git process, used by the Source Control
    /// tree view's folder tri-state checkbox.
    func setStaged(_ staged: Bool, paths: [String]) async {
        guard let rootURL, !paths.isEmpty else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            try await gitService.setStaged(staged, paths: paths, at: rootURL)
            await refreshGit()
        } catch { reportGitError(error) }
    }

    func stageAll() async {
        guard let rootURL else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            try await gitService.stageAll(at: rootURL)
            await refreshGit()
        } catch { reportGitError(error) }
    }

    func commit() async {
        guard let rootURL else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            _ = try await gitService.commit(message: gitCommitMessage, at: rootURL)
            gitCommitMessage = ""
            await refreshGit()
        } catch { reportGitError(error) }
    }

    func gitOpenChangeDiff(_ change: GitChange, scope: GitDiffScope) async {
        guard let rootURL else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            let diff = try await gitService.diff(
                GitDiffRequest(path: change.path, scope: scope),
                at: rootURL
            )
            let scopeTitle = scope == .staged ? "Staged" : "Working Tree"
            gitOpenDiff = GitOpenDiff(
                title: "Diff • \((change.path as NSString).lastPathComponent)",
                subtitle: "\(change.path) • \(scopeTitle)",
                diff: diff,
                identity: "\(scopeTitle):\(change.path)",
                scope: scope
            )
            selectedDocumentID = nil
            selectedTreePath = rootURL.appending(path: change.path).path
        } catch is CancellationError {
            return
        } catch {
            reportGitError(error)
        }
    }

    func gitSelectHistoryCommit(_ commit: GitCommitSummary) async {
        guard let rootURL else { return }
        gitSelectedHistoryCommitID = commit.id
        gitHistoryCommitChanges = []
        isGitHistoryDetailLoading = true
        isGitBusy = true
        defer {
            isGitBusy = false
            if gitSelectedHistoryCommitID == commit.id { isGitHistoryDetailLoading = false }
        }
        do {
            let changes = try await gitService.commitChanges(commit.id, at: rootURL)
            guard gitSelectedHistoryCommitID == commit.id else { return }
            gitHistoryCommitChanges = changes
        } catch is CancellationError {
            return
        } catch {
            reportGitError(error)
        }
    }

    func gitOpenHistoryDiff(_ change: GitCommitFileChange) async {
        guard let rootURL, let revision = gitSelectedHistoryCommitID else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            let diff = try await gitService.diff(
                GitDiffRequest(path: change.path, scope: .commit(revision)),
                at: rootURL
            )
            gitOpenDiff = GitOpenDiff(
                title: "Diff • \((change.path as NSString).lastPathComponent)",
                subtitle: "\(change.path) • \(String(revision.prefix(8)))",
                diff: diff,
                identity: "\(revision):\(change.path)",
                scope: .commit(revision)
            )
            selectedDocumentID = nil
            selectedTreePath = rootURL.appending(path: change.path).path
        } catch is CancellationError {
            return
        } catch {
            reportGitError(error)
        }
    }

    func selectGitDiff() {
        guard gitOpenDiff != nil else { return }
        selectedDocumentID = nil
    }

    func closeGitDiff() {
        let wasSelected = selectedDocumentID == nil
        gitOpenDiff = nil
        if wasSelected, let fallback = openDocuments.last {
            select(fallback)
        }
    }

    // MARK: - Hunk staging

    /// Stages one hunk of the currently open working-tree diff via
    /// `git apply --cached`, using `GitHunkPatchBuilder` to build the patch.
    func stageHunk(_ hunk: GitDiffHunk) async {
        guard let rootURL,
            let openDiff = gitOpenDiff,
            openDiff.scope == .workingTree,
            gitSnapshot?.changes.first(where: { $0.path == openDiff.diff.path })?.kind == .modified,
            !isGitBusy,
            !isGitHunkActionBusy
        else { return }

        isGitHunkActionBusy = true
        defer { isGitHunkActionBusy = false }
        do {
            let patch = try GitHunkPatchBuilder.patch(for: hunk, in: openDiff.diff)
            try await gitService.applyHunk(patch: patch, staging: true, at: rootURL)
            await refreshGit()
            let refreshed = try await gitService.diff(
                GitDiffRequest(path: openDiff.diff.path, scope: openDiff.scope),
                at: rootURL
            )
            guard gitOpenDiff?.id == openDiff.id else { return }
            if refreshed.isEmpty {
                closeGitDiff()
            } else {
                gitOpenDiff = GitOpenDiff(
                    title: openDiff.title,
                    subtitle: openDiff.subtitle,
                    diff: refreshed,
                    identity: openDiff.id,
                    scope: openDiff.scope
                )
            }
        } catch is CancellationError {
            return
        } catch {
            reportGitError(error)
        }
    }

    /// Unstages one hunk of the currently open staged diff via
    /// `git apply --cached --reverse`, using `GitHunkPatchBuilder` to build
    /// the reverse patch.
    func unstageHunk(_ hunk: GitDiffHunk) async {
        guard let rootURL,
            let openDiff = gitOpenDiff,
            openDiff.scope == .staged,
            gitSnapshot?.changes.first(where: { $0.path == openDiff.diff.path })?.kind == .modified,
            !isGitBusy,
            !isGitHunkActionBusy
        else { return }

        isGitHunkActionBusy = true
        defer { isGitHunkActionBusy = false }
        do {
            let patch = try GitHunkPatchBuilder.patch(for: hunk, in: openDiff.diff)
            try await gitService.applyHunk(patch: patch, staging: false, at: rootURL)
            await refreshGit()
            let refreshed = try await gitService.diff(
                GitDiffRequest(path: openDiff.diff.path, scope: openDiff.scope),
                at: rootURL
            )
            guard gitOpenDiff?.id == openDiff.id else { return }
            if refreshed.isEmpty {
                closeGitDiff()
            } else {
                gitOpenDiff = GitOpenDiff(
                    title: openDiff.title,
                    subtitle: openDiff.subtitle,
                    diff: refreshed,
                    identity: openDiff.id,
                    scope: openDiff.scope
                )
            }
        } catch is CancellationError {
            return
        } catch {
            reportGitError(error)
        }
    }

    // MARK: - Stash

    /// Pushes a new stash entry via `git stash push`.
    func stashChanges(message: String, includeUntracked: Bool) async {
        guard let rootURL, !isGitBusy, !isGitHunkActionBusy else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            try await gitService.stashPush(
                message: message,
                includeUntracked: includeUntracked,
                at: rootURL
            )
            guard self.rootURL == rootURL else { return }
            await refreshGit()
            let stashes = try await gitService.stashList(at: rootURL)
            guard self.rootURL == rootURL else { return }
            gitStashes = stashes
        } catch is CancellationError {
            return
        } catch {
            guard self.rootURL == rootURL else { return }
            reportGitError(error)
        }
    }

    /// Applies a stash entry without removing it.
    func applyStash(_ entry: GitStashEntry) async {
        guard let rootURL, !isGitBusy, !isGitHunkActionBusy else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            let current = try await gitService.stashList(at: rootURL)
            guard current.first(where: { $0.index == entry.index }) == entry else {
                throw GitServiceError.stashChanged
            }
            guard self.rootURL == rootURL else { return }
            try await gitService.stashApply(index: entry.index, at: rootURL)
            guard self.rootURL == rootURL else { return }
            await refreshGit()
            let stashes = try await gitService.stashList(at: rootURL)
            guard self.rootURL == rootURL else { return }
            gitStashes = stashes
        } catch is CancellationError {
            return
        } catch {
            if self.rootURL == rootURL {
                await refreshGit()
                if let stashes = try? await gitService.stashList(at: rootURL) {
                    guard self.rootURL == rootURL else { return }
                    gitStashes = stashes
                }
            }
            guard self.rootURL == rootURL else { return }
            reportGitError(error)
        }
    }

    /// Applies a stash entry and removes it.
    func popStash(_ entry: GitStashEntry) async {
        guard let rootURL, !isGitBusy, !isGitHunkActionBusy else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            let current = try await gitService.stashList(at: rootURL)
            guard current.first(where: { $0.index == entry.index }) == entry else {
                throw GitServiceError.stashChanged
            }
            guard self.rootURL == rootURL else { return }
            try await gitService.stashPop(index: entry.index, at: rootURL)
            guard self.rootURL == rootURL else { return }
            await refreshGit()
            let stashes = try await gitService.stashList(at: rootURL)
            guard self.rootURL == rootURL else { return }
            gitStashes = stashes
        } catch is CancellationError {
            return
        } catch {
            if self.rootURL == rootURL {
                await refreshGit()
                if let stashes = try? await gitService.stashList(at: rootURL) {
                    guard self.rootURL == rootURL else { return }
                    gitStashes = stashes
                }
            }
            guard self.rootURL == rootURL else { return }
            reportGitError(error)
        }
    }

    /// Discards a stash entry.
    func dropStash(_ entry: GitStashEntry) async {
        guard let rootURL, !isGitBusy, !isGitHunkActionBusy else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            let current = try await gitService.stashList(at: rootURL)
            guard current.first(where: { $0.index == entry.index }) == entry else {
                throw GitServiceError.stashChanged
            }
            guard self.rootURL == rootURL else { return }
            try await gitService.stashDrop(index: entry.index, at: rootURL)
            guard self.rootURL == rootURL else { return }
            await refreshGit()
            let stashes = try await gitService.stashList(at: rootURL)
            guard self.rootURL == rootURL else { return }
            gitStashes = stashes
        } catch is CancellationError {
            return
        } catch {
            guard self.rootURL == rootURL else { return }
            reportGitError(error)
        }
    }

    // MARK: - Blame

    /// Opens a read-only blame canvas for the selected file, parsing
    /// `git blame` porcelain output via `GitBlameParser`.
    func openBlameForSelectedFile() async {
        guard let rootURL,
            let document = selectedDocument,
            let gitSnapshot,
            let rawRepositoryRoot = gitSnapshot.repositoryRoot ?? self.rootURL,
            !isGitBusy
        else { return }
        guard !document.isDirty else {
            reportGitError(GitServiceError.blameRequiresSavedFile)
            return
        }

        let repositoryRoot = rawRepositoryRoot.standardizedFileURL
        let fileURL = document.url.standardizedFileURL
        let rootPath = repositoryRoot.path
        let filePath = fileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            reportGitError(GitServiceError.invalidGitPath)
            return
        }
        let relativePath = String(filePath.dropFirst(rootPath.count + 1))

        isGitBusy = true
        defer { isGitBusy = false }
        do {
            let blame = try await gitService.blame(
                forRelativePath: relativePath,
                at: repositoryRoot
            )
            guard self.rootURL == rootURL, selectedDocumentID == document.id else { return }
            gitOpenDiff = nil
            gitOpenBlame = blame
        } catch is CancellationError {
            return
        } catch {
            guard self.rootURL == rootURL else { return }
            reportGitError(error)
        }
    }

    /// Discards the retained blame data.
    func closeBlame() {
        gitOpenBlame = nil
    }

    func gitCreateBranch(named name: String) async {
        guard let rootURL else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            try await gitService.createBranch(named: name, at: rootURL)
            await refreshGit()
        } catch { reportGitError(error) }
    }

    func gitCheckoutBranch(named name: String) async {
        guard let rootURL else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            try await gitService.checkout(branch: name, at: rootURL)
            await refreshWorkspace()
            await refreshGit()
        } catch { reportGitError(error) }
    }

    func gitMergeBranch(named name: String) async {
        guard let rootURL else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            _ = try await gitService.merge(branch: name, at: rootURL)
            await refreshWorkspace()
            await refreshGit()
        } catch {
            await refreshGit()
            reportGitError(error)
        }
    }

    func gitFetch(remote: String? = nil) async {
        guard let rootURL else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            _ = try await gitService.fetch(GitFetchRequest(remote: remote), at: rootURL)
            await refreshGit()
        } catch { reportGitError(error) }
    }

    func gitPull(strategy: GitPullStrategy = .merge) async {
        guard let rootURL else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            _ = try await gitService.pull(GitPullRequest(strategy: strategy), at: rootURL)
            await refreshWorkspace()
            await refreshGit()
        } catch { reportGitError(error) }
    }

    func gitPush(remote: String? = nil) async {
        guard let rootURL else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            // A plain Push on a branch without an upstream would fail with
            // git's "no upstream branch" fatal even though a remote exists —
            // auto-publish instead ("origin" preferred, else the sole/first
            // remote), matching what git itself suggests.
            var resolvedRemote = remote
            if resolvedRemote == nil, gitBranchSnapshot?.upstream == nil {
                resolvedRemote =
                    gitRemoteNames.contains("origin") ? "origin" : gitRemoteNames.first
            }
            let request: GitPushRequest
            if let resolvedRemote, let branch = gitBranchSnapshot?.currentBranch {
                request = GitPushRequest(
                    remote: resolvedRemote,
                    branch: branch,
                    setUpstream: gitBranchSnapshot?.upstream == nil
                )
            } else {
                request = GitPushRequest()
            }
            _ = try await gitService.push(request, at: rootURL)
            await refreshGit()
        } catch { reportGitError(error) }
    }

    /// Per-line Git gutter markers for one open buffer. Returns `nil` when
    /// the workspace is not a repository or the file lives outside it, so
    /// callers can skip drawing without spawning any process. Untracked
    /// files are synthesized as all-added locally, also without a process.
    func gutterLineChanges(for document: EditorDocument) async -> GitGutterLineChanges? {
        guard let gitSnapshot,
            let repositoryRoot = gitSnapshot.repositoryRoot ?? rootURL
        else { return nil }
        let rootPath = repositoryRoot.standardizedFileURL.path
        let filePath = document.url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return nil }
        let relativePath = String(filePath.dropFirst(rootPath.count + 1))
        guard !relativePath.isEmpty else { return nil }

        let change = gitSnapshot.changes.first { $0.path == relativePath }
        if change?.kind == .untracked {
            guard let text = document.textSnapshotProvider?() else { return nil }
            let lineCount = 1 + text.utf8.count(where: { $0 == UInt8(ascii: "\n") })
            return .allAdded(lineCount: lineCount)
        }
        do {
            return try await gitService.lineChanges(
                forRelativePath: relativePath, at: repositoryRoot)
        } catch {
            return nil
        }
    }

    var gitRemoteNames: [String] {
        let names =
            gitBranchSnapshot?.remoteBranches.compactMap { branch in
                branch.name.split(separator: "/", maxSplits: 1).first.map(String.init)
            } ?? []
        return Array(Set(names)).sorted()
    }

    func generateAICommitMessage() async {
        guard !isGeneratingAICommitMessage else { return }
        isGeneratingAICommitMessage = true
        aiCommitGenerationError = nil
        defer { isGeneratingAICommitMessage = false }

        do {
            try Task.checkCancellation()
            guard let rootURL, let gitSnapshot else {
                throw AIProviderError.selectedDiffsRequired
            }

            let resolution = AICommitScopeSelection.resolve(
                selectedIDs: gitSelectedChangeIDs,
                allChanges: gitSnapshot.changes,
                stagedChanges: gitSnapshot.stagedChanges
            )
            let changes = resolution.changes
            guard !changes.isEmpty else { throw AIProviderError.selectedDiffsRequired }

            let configurations = try await aiConfigurationStore.load()
            let preferredID = await aiConfigurationStore.selectedConfigurationID()
            guard
                let configuration = preferredID.flatMap({ preferredID in
                    configurations.first(where: { $0.id == preferredID })
                }) ?? configurations.first
            else {
                throw AIProviderError.invalidConfiguration(
                    "Configure and save a commit-message provider in Settings first."
                )
            }
            guard let apiKey = try await aiSecretStore.secret(for: configuration.id) else {
                throw AIProviderError.missingAPIKey
            }

            var input = try await budgetedCommitPromptInput(
                changes: changes,
                rootURL: rootURL,
                stagedDiffsOnly: resolution.stagedDiffsOnly
            )
            input.mergeContext = gitMergeState?.headline

            let stream = try aiProviderClient.generateCommitMessage(
                configuration: configuration,
                apiKey: apiKey,
                input: input
            )
            var generatedMessage = ""
            for try await delta in stream {
                try Task.checkCancellation()
                generatedMessage += delta
                gitCommitMessage = generatedMessage
            }
            guard !generatedMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AIProviderError.malformedResponse
            }
        } catch is CancellationError {
            return
        } catch {
            aiCommitGenerationError = Self.boundedAIErrorMessage(error)
        }
    }

    /// Deterministically budgets which changed files get a full patch versus
    /// a stat-line summary, so `generateAICommitMessage` never hard-fails on
    /// changeset size. Fetches full diffs smallest-estimated-size first
    /// (`AICommitDiffOrdering`), stopping at `maximumFullDiffCount` files or
    /// the `maximumDiffBytes` budget; every other in-scope file becomes an
    /// `AICommitDiffSummary`. Bounded at two `numstat` processes plus at most
    /// `maximumFullDiffCount` diff fetches (each up to two processes for a
    /// partially staged file), independent of changeset size. A leaner
    /// single-process diff path is future work — not restructured here.
    private func budgetedCommitPromptInput(
        changes: [GitChange],
        rootURL: URL,
        stagedDiffsOnly: Bool
    ) async throws -> AICommitPromptInput {
        let lineStats = (try? await gitService.changeLineStats(at: rootURL)) ?? [:]
        var untrackedFileSizes: [String: Int] = [:]
        for change in changes where change.kind == .untracked {
            if let size = Self.fileByteSize(at: rootURL.appending(path: change.path)) {
                untrackedFileSizes[change.path] = size
            }
        }
        let ordered = AICommitDiffOrdering.order(
            changes: changes,
            lineStats: lineStats,
            untrackedFileSizes: untrackedFileSizes
        )

        var fullDiffs: [AISelectedDiff] = []
        var consumedBytes = 0
        var fetchedPaths: Set<String> = []
        fullDiffs.reserveCapacity(min(ordered.count, AICommitPromptBuilder.maximumFullDiffCount))

        for change in ordered {
            try Task.checkCancellation()
            guard fullDiffs.count < AICommitPromptBuilder.maximumFullDiffCount else { break }

            // In staged-only mode a partially staged file contributes just
            // its staged diff: the unstaged remainder is not part of the
            // commit this message will describe.
            let scopes =
                stagedDiffsOnly
                ? [AICommitDiffScope.staged]
                : AICommitDiffScopeResolver().scopes(
                    isStaged: change.isStaged,
                    hasUnstagedChanges: change.hasUnstagedChanges
                )
            var patches: [String] = []
            for scope in scopes {
                let gitScope: GitDiffScope =
                    switch scope {
                    case .staged: .staged
                    case .workingTree: .workingTree
                    }
                let diff = try await gitService.diff(
                    GitDiffRequest(path: change.path, scope: gitScope),
                    at: rootURL
                )
                patches.append("## \(scope.label)\n\(diff.rawPatch)")
            }
            let (patch, isTruncated) = AICommitPromptBuilder.truncated(
                patch: patches.joined(separator: "\n\n")
            )
            let patchBytes = patch.utf8.count
            guard consumedBytes + patchBytes <= AICommitPromptBuilder.maximumDiffBytes else {
                break
            }

            consumedBytes += patchBytes
            fullDiffs.append(
                AISelectedDiff(path: change.path, patch: patch, isTruncated: isTruncated)
            )
            fetchedPaths.insert(change.path)
        }

        let remaining = ordered.filter { !fetchedPaths.contains($0.path) }
        let summarized = remaining.prefix(AICommitPromptBuilder.maximumSummaryCount)
        let summaries = summarized.map { change -> AICommitDiffSummary in
            let stats = lineStats[change.path]
            let label = change.kind == .untracked ? "New file" : change.statusLabel
            let isBinary = stats?.isBinary ?? false
            return AICommitDiffSummary(
                path: change.path,
                statusLabel: label,
                added: isBinary ? nil : stats?.added,
                deleted: isBinary ? nil : stats?.deleted
            )
        }
        let overflowFileCount = remaining.count - summarized.count

        return AICommitPromptInput(
            fullDiffs: fullDiffs,
            summaries: summaries,
            overflowFileCount: overflowFileCount
        )
    }

    private static func fileByteSize(at url: URL) -> Int? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize
    }

    /// Git operation failures share the error alert but carry an honest
    /// title instead of "Unable to Open Folder".
    func reportGitError(_ error: any Error) {
        if error is CancellationError { return }
        openFolderErrorTitle = "Git Operation Failed"
        openFolderErrorMessage = error.localizedDescription
        isOpenFolderErrorPresented = true
    }

    func reportOpenFolderError(_ error: any Error) {
        // Superseded/cancelled tasks are routine (rapid refreshes during a
        // branch switch or FSEvents storm) and must never surface as a
        // user-facing failure alert.
        if error is CancellationError { return }
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        openFolderErrorTitle = "Unable to Open Folder"
        openFolderErrorMessage = error.localizedDescription
        isOpenFolderErrorPresented = true
    }

    isolated deinit {
        liveness.stop()
        restorationTask?.cancel()
        navigationTask?.cancel()
        indexRebuildTask?.cancel()
        symbolIndexRebuildTask?.cancel()
        languageIntelligence.workspaceDidClose()
        stopAccessingSecurityScopedURL()
    }

    private func stopAccessingSecurityScopedURL() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    func restoreLastWorkspaceIfAvailable() async {
        guard descriptor == nil else { return }
        do {
            guard let restored = try await restorationStore.load() else { return }
            let resolved = try await restorationStore.resolve(restored.bookmark)
            guard FileManager.default.fileExists(atPath: resolved.url.path),
                resolved.url.startAccessingSecurityScopedResource()
            else {
                await restorationStore.clear()
                return
            }

            securityScopedURL = resolved.url
            descriptor = WorkspaceDescriptor(
                displayName: resolved.url.lastPathComponent,
                location: .local(LocalWorkspaceReference(path: resolved.url.path))
            )
            navigationLadder = makeNavigationLadder(rootURL: resolved.url)
            navigatorMode = restored.navigatorMode
            workspaceSearch.loadHistory(for: resolved.url)
            resetFileTreeState()
            startFileWatcher()
            await refreshWorkspace()

            languageIntelligence.workspaceDidOpen(root: resolved.url)
            for relativePath in restored.openRelativePaths {
                let url = resolved.url.appending(path: relativePath)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                _ = trackNewDocument(url: url)
            }
            restoreEditorLayout(restored.editorLayout, from: restored.rootPath, to: resolved.url)
            if let selected = restored.selectedRelativePath,
                let document = openDocuments.first(where: {
                    relativePath(for: $0.url) == selected
                })
            {
                select(document)
            } else if let first = openDocuments.first {
                select(first)
            }
            applyRestoredHibernationPlaceholders()

            if resolved.isStale { persistWorkspaceState() }
        } catch {
            await restorationStore.clear()
        }
    }

    private func persistWorkspaceState() {
        guard let rootURL else { return }
        let openPaths = openDocuments.map { relativePath(for: $0.url) }
        let selectedPath = selectedDocument.map { relativePath(for: $0.url) }
        let navigatorMode = navigatorMode
        restorationTask?.cancel()
        restorationTask = Task(name: "Persist workspace restoration") { [restorationStore] in
            do {
                let bookmark = try await restorationStore.makeBookmark(for: rootURL)
                try Task.checkCancellation()
                try await restorationStore.save(
                    RestorableWorkspace(
                        bookmark: bookmark,
                        rootPath: rootURL.path,
                        openRelativePaths: openPaths,
                        selectedRelativePath: selectedPath,
                        navigatorMode: navigatorMode,
                        editorLayout: EditorLayoutRestoration(layout: editorLayout)
                    )
                )
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func reconcileGitSelection() {
        let liveIDs = Set(gitSnapshot?.changes.map(\.id) ?? [])
        gitSelectedChangeIDs.formIntersection(liveIDs)
    }

    /// Recomputes `gitTreeBadges` from the current snapshot. Called from
    /// `gitSnapshot.didSet`, so every snapshot refresh (and clear) keeps the
    /// file-tree decorations in sync without any per-row work.
    private func rebuildGitTreeBadges() {
        guard let snapshot = gitSnapshot, let rootURL else {
            if !gitTreeBadges.isEmpty { gitTreeBadges = [:] }
            return
        }
        gitTreeBadges = snapshot.treeBadges(workspaceRoot: rootURL)
    }

    private func resetGitWorkbenchState() {
        gitSnapshot = nil
        gitSelectedChangeIDs = []
        gitBranchSnapshot = nil
        gitHistoryPage = nil
        gitSelectedHistoryCommitID = nil
        gitHistoryCommitChanges = []
        isGitHistoryDetailLoading = false
        gitOpenDiff = nil
        gitMergeState = nil
    }

    private static func boundedAIErrorMessage(_ error: any Error) -> String {
        let message =
            (error as? LocalizedError)?.errorDescription
            ?? "Commit-message generation failed."
        return String(decoding: message.utf8.prefix(512), as: UTF8.self)
    }

    private func synchronizeSelectionFromLayout(fallback: EditorDocument? = nil) {
        let group = editorLayout.group(id: editorLayout.focusedGroupID)
        let document =
            group?.selectedTabID.flatMap { tabID in
                group?.tabs.first(where: { $0.id == tabID }).flatMap(document(for:))
            } ?? fallback
        selectedDocumentID = document?.id
        selectedTreePath = document?.url.path
    }

    private func restoreEditorLayout(
        _ restoration: EditorLayoutRestoration?,
        from oldRootPath: String,
        to newRootURL: URL
    ) {
        guard let restoration, var layout = try? restoration.restoredLayout() else {
            editorLayout = EditorLayoutState()
            for document in openDocuments {
                editorLayout.insert(
                    EditorTabState(resource: .file(document.url)),
                    in: editorLayout.focusedGroupID
                )
            }
            return
        }

        let oldRootURL = URL(fileURLWithPath: oldRootPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let newRootURL = newRootURL.resolvingSymlinksInPath().standardizedFileURL
        let openURLs = Set(
            openDocuments.map { $0.url.resolvingSymlinksInPath().standardizedFileURL })

        for groupID in layout.groupIDs {
            let tabs = layout.group(id: groupID)?.tabs ?? []
            for tab in tabs {
                guard case .file(let savedURL) = tab.resource,
                    let rebasedURL = rebase(savedURL, from: oldRootURL, to: newRootURL),
                    openURLs.contains(rebasedURL.resolvingSymlinksInPath().standardizedFileURL)
                else {
                    _ = layout.closeTab(tab.id)
                    continue
                }
                layout.updateResource(for: tab.id, to: .file(rebasedURL))
            }
        }
        layout.collapseEmptyGroups()
        editorLayout = layout
    }

    private func rebase(_ fileURL: URL, from oldRootURL: URL, to newRootURL: URL) -> URL? {
        let filePath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        let oldRootPath = oldRootURL.path
        guard filePath == oldRootPath || filePath.hasPrefix(oldRootPath + "/") else { return nil }
        let relativePath = String(filePath.dropFirst(oldRootPath.count)).trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        guard !relativePath.isEmpty else { return nil }
        return newRootURL.appending(path: relativePath).standardizedFileURL
    }
}

private enum WorkspaceOpenError: LocalizedError {
    case securityScopedAccessDenied

    var errorDescription: String? {
        switch self {
        case .securityScopedAccessDenied:
            "macOS did not grant access to the selected folder. The current workspace was left unchanged."
        }
    }
}
