import AppKit
import Foundation
import Observation
import RafuCore

// `nonisolated`: without it, the target's default `MainActor` isolation
// (`Package.swift`) makes the custom `init(from:)` below MainActor-isolated,
// which in turn makes the whole `Decodable` conformance MainActor-isolated —
// unusable from a plain (non-`@MainActor`) `JSONDecoder().decode(...)` call
// such as `WorkspaceRestorationStore.load()`'s `@concurrent` context or a
// headless test. This is a pure, `Sendable` value type; it never needed
// actor isolation.
nonisolated enum WorkspaceNavigatorMode: String, CaseIterable, Codable, Sendable {
    case files
    case search
    case sourceControl
    case terminals
    /// Conductor runs (ADR 0018, conductor/C0-shim.md). The tolerant decode
    /// below already protects restoration for builds that predate this case.
    case runs

    var title: String {
        switch self {
        case .files: "Files"
        case .search: "Search"
        case .sourceControl: "Source Control"
        case .terminals: "Terminals"
        case .runs: "Runs"
        }
    }

    var symbolName: String {
        switch self {
        case .files: "doc.on.doc"
        case .search: "magnifyingglass"
        case .sourceControl: "arrow.triangle.branch"
        case .terminals: "terminal"
        case .runs: "list.bullet.rectangle"
        }
    }

    /// Tolerant decode: a persisted raw value this build does not know (an
    /// older build reading a newer `RestorableWorkspace`) falls back to
    /// `.files` instead of throwing. Without this, ONE unknown mode string
    /// fails the whole `RestorableWorkspace` decode and
    /// `restoreLastWorkspaceIfAvailable()`'s catch clears restoration —
    /// losing the folder, open documents and split layout, not just the mode.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = WorkspaceNavigatorMode(rawValue: raw) ?? .files
    }
}

@Observable
@MainActor
final class WorkspaceSession {
    enum TerminalGroupPresentationAction: Hashable {
        case toggle, newGroup, splitRight, splitDown
        case focus(TerminalPaneFocusDirection)
        case rename, save, saveAs, setFolder, startPane, startAll, hide, closePane, closeGroup
    }

    struct TerminalGroupPresentationAvailability: Equatable {
        let isEnabled: Bool
        let reason: String?
    }
    struct TerminalGroupSaveRequest: Identifiable, Equatable {
        enum Kind: Equatable { case firstSave, saveAs }
        let id: TerminalGroupID
        let kind: Kind
        var proposedName: String
    }

    /// Ephemeral, window-owned presentation input. The terminal runtime keeps
    /// the authoritative name; this request only holds a bounded user draft.
    struct TerminalGroupRenameRequest: Identifiable, Equatable {
        let id: TerminalGroupID
        var proposedName: String
    }

    /// Ephemeral, window-owned folder-picker input. It intentionally retains
    /// no live controller, terminal session, output, or observed CWD.
    struct TerminalPaneStartingFolderRequest: Identifiable, Equatable {
        let id: TerminalPaneID
        let initialDirectory: URL?
    }

    struct FileCreationRequest {
        let parentURL: URL
        let isDirectory: Bool
    }

    /// Cache key for `workingTreeDiffCache` — see its doc comment.
    private struct WorkingTreeDiffCacheKey: Hashable {
        let path: String
        let revision: Int
    }

    /// The proposed content and per-pattern reasons for the currently open
    /// `IgnoreSuggestionSheet`, plus a locally editable copy of the content
    /// the user can tweak before accepting (see `acceptIgnoreSuggestion(content:)`).
    struct IgnoreSuggestionState {
        var kind: IgnoreFileKind
        var proposed: ProposedIgnore
        var editableContent: String
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
    /// Window-scoped, non-persisted Ctrl-Tab selection. The overlay previews
    /// this value and commits its destination only when Control is released.
    private(set) var editorTabSwitcherState: EditorTabSwitcherState?
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
    var gitWorktrees: [GitWorktree] = []
    var isGitWorktreesLoading = false
    var gitOpenBlame: GitBlame?
    /// Per-window GX1 inline-blame ghost-annotation toggle (View menu /
    /// command palette "Toggle Inline Blame"). Off by default (ADR 0013,
    /// GD2 — a calm default) and deliberately NOT persisted across
    /// launches: every new window starts with it off.
    var isInlineBlameEnabled = false
    /// Issue #15: per-window full-file blame toggle — annotates EVERY line
    /// (committed and uncommitted alike) with its author and relative date,
    /// unlike GX1's single caret-line ghost. Off by default (same calm-UI
    /// default as inline blame, ADR 0013 GD2) and never persisted.
    var isFileBlameAnnotationsEnabled = false
    /// Build-level feature flag: AI tab-completion is not ready to ship yet.
    /// While false, the Edit-menu item and palette entry are hidden and
    /// `toggleAICompletion()` is a no-op, so the mode can never turn on.
    /// Flip to true when the feature is finished.
    nonisolated static let isAICompletionFeatureAvailable = false
    /// AI tab-completion mode; per-window, off by default, never persisted.
    var isAICompletionEnabled = false
    /// Set at the end of a successful explicit `gitFetch(remote:)` — the
    /// GX3 commit-graph header's "last fetched" label. Never advances on
    /// its own; Rafu never fetches automatically.
    var gitLastFetchedAt: Date?
    var gitCommitMessage = ""
    var isGeneratingAICommitMessage = false
    var aiCommitGenerationError: String?
    /// Explicit "Publish to GitHub" flow (a repository with no `origin`
    /// remote) — see `publishToGitHub(name:visibility:)`.
    var isGitHubPublishPresented = false
    var isPublishingToGitHub = false
    /// Drives `IgnoreSuggestionSheet`'s presentation. Set the moment
    /// `startIgnoreSuggestion(kind:)` runs — before the AI reply arrives —
    /// so the sheet can show a loading state while `isSuggestingIgnore` is
    /// still true, rather than only appearing once `ignoreSuggestion` has
    /// content.
    var isIgnoreSuggestionPresented = false
    /// The completed AI ignore-file suggestion once the reply has been
    /// parsed; `nil` while loading or when no suggestion has been requested.
    var ignoreSuggestion: IgnoreSuggestionState?
    var isSuggestingIgnore = false
    var ignoreSuggestionError: String?
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

    /// Conductor run seams (ADR 0018, conductor/C0-shim.md), pre-landed here
    /// exactly as the git phase pre-landed its seams so C1's run engine and
    /// C5's runs navigator fill them WITHOUT editing this shared file.
    ///
    /// C1 reloads persisted manifests eagerly (`reloadConductorRuns(for:)`,
    /// called from both `openLocalWorkspace(at:)` and
    /// `restoreLastWorkspaceIfAvailable()`), so this reflects `.rafu/runs/`
    /// as read at the moment a workspace opens, replaces, or restores — not
    /// only when the `.runs` navigator panel happens to be mounted.
    var conductorRuns: [ConductorRunManifest] {
        conductorRunController.runs
    }
    /// The run the `.runs` panel and (C5) the run-detail canvas are showing.
    var selectedConductorRunID: String?

    /// Non-nil while the editor canvas hosts the run-detail timeline (C5).
    /// Distinct from `selectedConductorRunID` (the panel's own selection,
    /// which persists across canvas visibility): revealing a live step's
    /// terminal must REPLACE the canvas, not sit behind it, so
    /// `revealTerminalSession(_:)` clears this while leaving the panel
    /// selection alone.
    var conductorRunCanvasID: String?

    /// This window's run engine — C1 FILLS IT (`conductor/C1-single-role-runs
    /// .md`). Pre-landed here because C1 may not add stored properties to
    /// this shared file without stopping to report, and because one window
    /// owns exactly one run controller, the same way it owns one terminal
    /// manager.
    ///
    /// Constructing it does NO work: it only captures the adapter registry
    /// (seven pure value types) and holds `.idle` state. Nothing runs, and
    /// no `.rafu/` path is touched, until C1's explicit user-initiated run
    /// (ADR 0018).
    /// The adapter registry every conductor engine in this window resolves
    /// against. Defaults to the real one; tests inject `FakeConductorAdapter`
    /// so orchestration behaviour stays verifiable on a machine with no
    /// vendor CLI installed — a CI runner has none, and a test that reaches
    /// the real registry there fails with "agent adapter is unavailable"
    /// while passing on any developer Mac that happens to have Claude Code.
    @ObservationIgnored
    private let conductorAdapters: [any ConductorCLIAdapter]

    @ObservationIgnored
    let conductorRunController: ConductorRunController

    init(conductorAdapters: [any ConductorCLIAdapter] = ConductorAdapterRegistry.all) {
        self.conductorAdapters = conductorAdapters
        self.conductorRunController = ConductorRunController(adapters: conductorAdapters)
    }

    /// This window's C5 pipeline engine — a PEER of `conductorRunController`,
    /// publishing every manifest write through it (`ConductorRunController
    /// .publish`). `lazy` so a window that never starts a workflow run never
    /// constructs it; `onGateReady` is wired once, here, rather than at every
    /// call site.
    @ObservationIgnored
    private(set) lazy var conductorWorkflowController: ConductorWorkflowController = {
        let controller = ConductorWorkflowController(
            runsPublisher: conductorRunController,
            adapters: conductorAdapters)
        controller.onGateReady = { [weak self] event in
            self?.raiseConductorGateAttention(event)
        }
        return controller
    }()

    /// This window's C6 bounded pool of pipeline engines — the durable owner
    /// of every run started from the Runs panel. `conductorWorkflowController`
    /// above remains the fallback for a run this pool no longer tracks (it
    /// prunes completed/aborted runs) so historical selections still resolve.
    /// Route every gate/abort/retry/reveal verb through
    /// `workflowController(forRunID:)`, never the singular controller directly.
    @ObservationIgnored
    private(set) lazy var conductorConcurrentRuns: ConductorConcurrentRunCoordinator = {
        let coordinator = ConductorConcurrentRunCoordinator(
            runsPublisher: conductorRunController,
            adapters: conductorAdapters)
        coordinator.onGateReady = { [weak self] event in
            self?.raiseConductorGateAttention(event)
        }
        return coordinator
    }()

    /// Resolves the engine that owns `runID`: the concurrent pool first, then
    /// the singular controller when its current manifest matches. Returns
    /// `nil` for a historical run no live engine owns — callers must treat that
    /// as "no verbs available", not as an error.
    func workflowController(forRunID runID: String?) -> ConductorWorkflowController? {
        guard let runID else { return nil }
        if let owned = conductorConcurrentRuns.controller(runID: runID) { return owned }
        return conductorWorkflowController.manifest?.id == runID
            ? conductorWorkflowController : nil
    }

    /// The engine driving the run the UI is currently showing, if any.
    var selectedWorkflowController: ConductorWorkflowController? {
        workflowController(forRunID: selectedConductorRunID)
    }

    /// Adopts a persisted, interrupted run (C7 recovery) into a live engine so
    /// its Retry Step / Abort / Keep Worktree verbs work in this app process.
    /// Idempotent: a run already owned by an engine is returned as-is. Returns
    /// `nil` when the run cannot be adopted — the caller then shows it as
    /// read-only history rather than offering verbs that would do nothing.
    @discardableResult
    func adoptInterruptedRun(_ runID: String) -> ConductorWorkflowController? {
        if let existing = workflowController(forRunID: runID) { return existing }
        guard let rootURL,
            let manifest = conductorRuns.first(where: { $0.id == runID }),
            manifest.steps.contains(where: { $0.status == .interrupted })
        else { return nil }

        let launcher = WorkspaceConductorRunLauncher(workspaceSession: self, runID: runID)
        // Adopted into the singular controller, not the concurrent pool: the
        // pool's `start` is for NEW runs (it reserves a run id and materializes
        // a worktree), while this run's worktree already exists on disk.
        guard
            conductorWorkflowController.restoreInterrupted(
                manifest: manifest,
                workspaceRoot: rootURL,
                launcher: launcher)
        else { return nil }
        return conductorWorkflowController
    }

    /// Whether this window may start another pipeline. C6 deliberately allows
    /// several at once, so this is a CAP check (`activeLimit`), not an
    /// is-anything-running check — the pre-C6 guard was the latter and would
    /// have silently kept the concurrency story unreachable.
    var canStartConductorWorkflowRun: Bool {
        conductorRunController.canStartNewRun
            && !conductorWorkflowController.isInFlight
            && conductorConcurrentRuns.activeCount < conductorConcurrentRuns.activeLimit
    }

    private(set) var conductorCoordinatorSessions: [ConductorCoordinatorSession] = []

    @ObservationIgnored
    private var conductorCoordinatorEndHandlers: [String: @MainActor () -> Void] = [:]

    func registerCoordinatorSession(
        _ coordinatorSession: ConductorCoordinatorSession,
        onEnd: @escaping @MainActor () -> Void = {}
    ) {
        if let index = conductorCoordinatorSessions.firstIndex(where: {
            $0.id == coordinatorSession.id
        }) {
            conductorCoordinatorSessions[index] = coordinatorSession
        } else {
            conductorCoordinatorSessions.append(coordinatorSession)
        }
        conductorCoordinatorEndHandlers[coordinatorSession.id] = onEnd
    }

    func coordinatorSessionDidEnd(_ id: String) {
        guard let index = conductorCoordinatorSessions.firstIndex(where: { $0.id == id }),
            conductorCoordinatorSessions[index].endedAt == nil
        else { return }
        conductorCoordinatorSessions[index].endedAt = Date()
        let onEnd = conductorCoordinatorEndHandlers.removeValue(forKey: id)
        onEnd?()
    }

    private func endCoordinatorSession(for terminalSessionID: UUID) {
        guard
            let coordinatorID = conductorCoordinatorSessions.first(where: {
                $0.terminalSessionID == terminalSessionID && $0.endedAt == nil
            })?.id
        else { return }
        coordinatorSessionDidEnd(coordinatorID)
    }

    private func endAllCoordinatorSessions() {
        for id in conductorCoordinatorSessions.filter({ $0.endedAt == nil }).map(\.id) {
            coordinatorSessionDidEnd(id)
        }
    }

    /// Single terminal teardown funnel for workspace replacement, window
    /// close, and app termination. It is intentionally idempotent: callbacks
    /// and controllers are both removed before a second path can observe them.
    func teardownTerminalGroups() {
        guard !didTeardownTerminalGroups else { return }
        didTeardownTerminalGroups = true
        endTerminalGroupLibrary()
        cleanupTerminalSessions(terminal.sessions.map(\.id))
        endAllCoordinatorSessions()
        drainTerminalLifecycleCallbacks()
        terminal.shutdownAll()
        pendingTerminalGroupClose = nil
        pendingTerminalGroupSaveRequest = nil
        clearTerminalGroupPresentationRequests()
    }

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

    /// GX1 single-entry cache backing `inlineBlame(for:)` — retains only the
    /// active file's blame (see `InlineBlameStore`).
    @ObservationIgnored
    private var inlineBlameStore = InlineBlameStore()

    /// GX2 single-entry cache backing `workingTreeDiff(for:)`, mirroring
    /// `InlineBlameStore`'s "active file only" retention: keyed by
    /// (repo-relative path, buffer revision), evicted wholesale by a new key.
    @ObservationIgnored
    private var workingTreeDiffCache: (key: WorkingTreeDiffCacheKey, diff: GitFileDiff)?

    @ObservationIgnored
    private let aiConfigurationStore = UserDefaultsAIProviderConfigurationStore()

    @ObservationIgnored
    private let aiSecretStore = KeychainAISecretStore()

    @ObservationIgnored
    private let aiProviderClient = AIProviderClient()

    /// The in-flight AI commit-message generation, owned so the composer's
    /// Stop button (`cancelAICommitGeneration()`) can interrupt it — see
    /// `startAICommitGeneration()`.
    @ObservationIgnored
    private var aiCommitGenerationTask: Task<Void, Never>?

    /// The in-flight ignore-file suggestion request, owned so
    /// `IgnoreSuggestionSheet`'s Cancel can interrupt it — see
    /// `startIgnoreSuggestion(kind:)`.
    @ObservationIgnored
    private var ignoreSuggestionTask: Task<Void, Never>?

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

    /// Reveals a Conductor run (ADR 0018). C0 only records the selection and
    /// opens the `.runs` navigator so the seam is typed and exercised; C5
    /// adds the editor-hosted run-detail canvas behind the same call, so no
    /// caller changes when it lands. Reading run evidence starts nothing.
    func openConductorRun(_ runID: String) {
        installTerminalHandlersIfNeeded()
        selectedConductorRunID = runID
        navigatorMode = .runs
        conductorRunController.revealLiveTerminal(for: runID, in: self)
    }

    /// Hosts the run-detail timeline in the editor canvas (C5) — the Runs
    /// panel's row-selection path. Clears the file selection so
    /// `EditorCanvasView` routes to the canvas instead of a document, the
    /// same additive branch pattern `GitStandaloneDiffCanvas` established.
    func showConductorRunDetail(_ runID: String) {
        selectedConductorRunID = runID
        navigatorMode = .runs
        conductorRunCanvasID = runID
        conductorGraphVisible = false
        ensembleStartCanvasVisible = false
        ensembleNewRunCanvasVisible = false
        settingsVisible = false
        selectedDocumentID = nil
        selectedTreePath = nil
    }

    /// Leaves the run-detail canvas, falling back to the last open document
    /// tab (if any) exactly like `closeGitDiff()`'s fallback.
    func closeConductorRunDetail() {
        guard conductorRunCanvasID != nil else { return }
        conductorRunCanvasID = nil
        if selectedDocumentID == nil, let fallback = openDocuments.last {
            select(fallback)
        }
    }

    /// Hosts the workspace-wide Ensemble projection in the editor canvas.
    /// Graph, run detail, and terminal are peer occupants: opening one clears
    /// the other canvas route without changing the Runs panel selection.
    var conductorGraphVisible = false

    func showConductorGraph() {
        conductorGraphVisible = true
        conductorRunCanvasID = nil
        ensembleStartCanvasVisible = false
        ensembleNewRunCanvasVisible = false
        settingsVisible = false
        selectedDocumentID = nil
        selectedTreePath = nil
        navigatorMode = .runs
    }

    func closeConductorGraph() {
        guard conductorGraphVisible else { return }
        conductorGraphVisible = false
        if selectedDocumentID == nil, let fallback = openDocuments.last {
            select(fallback)
        }
    }

    /// Editor-hosted Ensemble creation canvases (UX-01). These are peers of
    /// graph and run detail: every activator clears the other canvas modes,
    /// and closing falls back to the last open document exactly like
    /// `closeConductorRunDetail()`.
    var ensembleStartCanvasVisible = false
    var ensembleNewRunCanvasVisible = false
    @ObservationIgnored private var ensembleStartLaunchInProgress = false

    /// Hosts Settings as a window-scoped, non-restorable editor canvas.
    /// The native Settings scene remains the no-window fallback for ⌘,;
    /// focused workspace windows route here instead.
    var settingsVisible = false

    func showSettings() {
        closeBlame()
        if gitOpenDiff != nil {
            closeGitDiff()
        }
        settingsVisible = true
        conductorRunCanvasID = nil
        conductorGraphVisible = false
        // UX-01 landed the creation canvases in parallel with this one, so
        // neither branch cleared the other's flags. Settings is their peer:
        // without these two lines the resolver's ordering silently becomes
        // load-bearing (editor-canvas-routing.md, "Exclusivity lives in the
        // mutators").
        ensembleStartCanvasVisible = false
        ensembleNewRunCanvasVisible = false
        selectedDocumentID = nil
        selectedTreePath = nil
    }

    func closeSettings() {
        guard settingsVisible else { return }
        settingsVisible = false
        if selectedDocumentID == nil, let fallback = openDocuments.last {
            select(fallback)
        }
    }

    /// C8-07's four "New Ensemble…" entry points share this guarded seam.
    func showEnsembleStart() {
        guard descriptor != nil else { return }
        ensembleStartCanvasVisible = true
        ensembleNewRunCanvasVisible = false
        conductorGraphVisible = false
        conductorRunCanvasID = nil
        settingsVisible = false
        selectedDocumentID = nil
        selectedTreePath = nil
        navigatorMode = .runs
    }

    func closeEnsembleStart() {
        guard ensembleStartCanvasVisible else { return }
        ensembleStartCanvasVisible = false
        if selectedDocumentID == nil, let fallback = openDocuments.last {
            select(fallback)
        }
    }

    /// Coordinator launch reveals its terminal as part of starting Door 1.
    /// Keep the copyable-goal confirmation canvas in front during that
    /// internal reveal; an ordinary user-requested terminal reveal still
    /// replaces the canvas.
    func beginEnsembleStartLaunch() {
        ensembleStartLaunchInProgress = true
    }

    func endEnsembleStartLaunch() {
        ensembleStartLaunchInProgress = false
    }

    func showEnsembleNewRun() {
        guard descriptor != nil, canStartConductorWorkflowRun else { return }
        ensembleNewRunCanvasVisible = true
        ensembleStartCanvasVisible = false
        conductorGraphVisible = false
        conductorRunCanvasID = nil
        settingsVisible = false
        selectedDocumentID = nil
        selectedTreePath = nil
        navigatorMode = .runs
    }

    func closeEnsembleNewRun() {
        guard ensembleNewRunCanvasVisible else { return }
        ensembleNewRunCanvasVisible = false
        if selectedDocumentID == nil, let fallback = openDocuments.last {
            select(fallback)
        }
    }

    /// Drives `WorkspaceWindowView`'s `NavigationSplitView` column
    /// visibility — the ⌘B Files/Search/Source Control sidebar toggle
    /// (issue #14). ADR 0002's "one system sidebar toggle" stays true: this
    /// is a keyboard path to the SAME visibility the split view's own
    /// built-in toolbar toggle controls, not a second affordance.
    var isSidebarCollapsed = false

    func toggleSidebar() {
        isSidebarCollapsed.toggle()
    }

    @ObservationIgnored
    let terminal = WorkspaceTerminalManager()

    // Terminal Groups are owned by this window session. The saved-layout
    // actor is process-wide, but its result is always guarded by this
    // session's workspace generation before it reaches visible state.
    private(set) var savedTerminalGroups: [SavedTerminalGroupRecord] = []
    private(set) var terminalGroupStoreError: String?
    private(set) var terminalGroupRestorationError: String?
    private(set) var pendingTerminalGroupClose: TerminalGroupCloseToken?
    private(set) var terminalGroupClosePresentationRevision: UInt64 = 0
    @ObservationIgnored var terminalGroupCloseRepreparedForTesting: (@MainActor () -> Void)?
    private(set) var pendingTerminalGroupSaveRequest: TerminalGroupSaveRequest?
    /// Window-owned sheet state. It prevents a second submit while the one
    /// saved-layout mutation is in flight.
    private(set) var isPendingTerminalGroupSaveSubmission = false
    private(set) var pendingTerminalGroupRenameRequest: TerminalGroupRenameRequest?
    private(set) var pendingTerminalPaneStartingFolderRequest: TerminalPaneStartingFolderRequest?
    private(set) var terminalGroupFocusRequest = UInt64(0)
    @ObservationIgnored private var terminalGroupStoreTask: Task<Void, Never>?
    @ObservationIgnored private var terminalGroupChangeTask: Task<Void, Never>?
    @ObservationIgnored private var terminalGroupWorkspaceGeneration: UInt64 = 0
    @ObservationIgnored private var terminalGroupListEpoch: UInt64 = 0
    @ObservationIgnored private var terminalGroupMutationEpoch: UInt64 = 0
    @ObservationIgnored private var terminalGroupSavePresentationEpoch: UInt64 = 0
    @ObservationIgnored private var terminalGroupMutationTask: Task<Void, Never>?
    /// Test-only completion observation for a cancelled stale save task.
    @ObservationIgnored var terminalGroupSaveTaskFinishedForTesting: (@MainActor () -> Void)?
    @ObservationIgnored var terminalGroupListFinishedForTesting: (@MainActor (UInt64) -> Void)?
    /// Test and app-identity injection seam. `nil` resolves the one shared
    /// actor, while a supplied actor gives every operation in this window the
    /// same isolated authority without touching developer Application Support.
    @ObservationIgnored var terminalGroupSavedLayoutStore: (any TerminalGroupSavedLayoutStoring)?
    @ObservationIgnored private var terminalLifecycleCallbacks: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var didTeardownTerminalGroups = false

    @ObservationIgnored
    private let shellCatalog = TerminalShellCatalog()
    @ObservationIgnored
    private let preferredShellStore = PreferredShellStore()
    /// `TerminalShellCatalog.shells()` reads `/etc/shells` and probes the
    /// filesystem — compute it once per session lifetime and never call
    /// `shellCatalog.shells()` directly from a `View.body`/`Commands` body.
    @ObservationIgnored
    private lazy var cachedTerminalShells: [TerminalShell] = shellCatalog.shells()

    @ObservationIgnored
    private var didInstallTerminalHandlers = false
    /// Injectable seam for a system attention notification (terminal-manager
    /// .md T-E) — `nil` by default, and never assigned the real
    /// `UNUserNotifications`-backed `SystemTerminalAttentionNotifier` except
    /// lazily, in `resolvedAttentionNotifier()`, the FIRST time a bell would
    /// actually notify. Tests substitute a spy here so no headless test
    /// path ever constructs the concrete notifier (it needs a signed
    /// bundle identity `swift test` does not have).
    @ObservationIgnored
    var attentionNotifier: (any TerminalAttentionNotifying)?
    @ObservationIgnored
    /// Not `private` (mirroring `attentionNotifier`) so tests can inject a
    /// store backed by an isolated `UserDefaults` suite instead of the
    /// real standard defaults — needed to test the preference-off gate in
    /// `notifyIfNeeded(for:)` without polluting the developer's actual
    /// setting under `swift test --no-parallel`.
    @ObservationIgnored
    var terminalAttentionSurfaceStore = TerminalAttentionSurfaceStore()

    /// Injectable seam for the notch HUD (terminal-notch-hud.md N-3) —
    /// `nil` by default and resolved to `NotchHUDController.shared` lazily,
    /// mirroring `attentionNotifier`, so tests substitute a spy and no
    /// headless test ever constructs the real panel.
    @ObservationIgnored
    var attentionHUD: (any NotchHUDPresenting)?

    /// The HUD belongs to no window/scene, so its theme is resolved HERE —
    /// at show time, from the same inputs `WorkspaceSceneRoot` uses — and
    /// passed into `show` by value (terminal-notch-hud.md N-4). Injectable
    /// so tests never read the real `themeChoice` default.
    @ObservationIgnored
    var hudThemeProvider: () -> RafuTheme = {
        RafuThemeCatalog.resolvedForCurrentAppearance()
    }

    /// Shells discovered on this machine (terminal-manager.md T-C), default
    /// first. See `cachedTerminalShells`'s doc comment for the caching rule.
    var availableTerminalShells: [TerminalShell] { cachedTerminalShells }

    private func preferredTerminalShell() -> TerminalShell {
        let shells = availableTerminalShells
        return preferredShellStore.resolved(in: shells)
            ?? shells.first(where: \.isDefault)
            ?? shells.first
            ?? TerminalShell(
                path: TerminalShellCatalog.environmentShellPath(), name: "Default", isDefault: true)
    }

    /// Wires `terminal.sessionDidExit`/`sessionDidBell` on first use — lazy
    /// so a workspace that never opens a terminal never installs the hooks,
    /// and registers this workspace with `TerminalAttentionCenter` so a
    /// notification reply (which arrives with no window context) can find
    /// it. `[weak self]` is mandatory: `terminal` is a stored, non-observed
    /// strong property, and a strong `self` here would retain-cycle
    /// session → terminal → closure → session.
    private func installTerminalHandlersIfNeeded() {
        guard !didInstallTerminalHandlers else { return }
        didInstallTerminalHandlers = true
        terminal.memoryTimelineSource = { [weak self] in self?.memoryTimelineSource ?? "" }
        terminal.sessionDidExit = { [weak self] sessionID, exitCode in
            self?.terminalSessionDidExit(sessionID, exitCode: exitCode)
        }
        terminal.sessionDidBell = { [weak self] sessionID in
            self?.terminalSessionDidBell(sessionID)
        }
        terminal.sessionDidClearAttention = { [weak self] sessionID in
            self?.terminalSessionDidClearAttention(sessionID)
        }
        TerminalAttentionCenter.shared.register(self)
    }

    /// `.bell` cleared for any reason (tab selected, session revealed,
    /// reply sent): the notch HUD dismisses — it re-presents attention
    /// state, it does not own it (terminal-notch-hud.md). The companion
    /// strip's resting-state attention dot re-derives from the same
    /// `.bell`/`.running`/`.exited` statuses, so it refreshes here too
    /// (terminal-notch-hud.md NC-B) — cheap and only on an actual state
    /// change, never polled.
    private func terminalSessionDidClearAttention(_ sessionID: UUID) {
        resolvedAttentionHUD().attentionCleared(for: sessionID)
        NotchCompanionModel.shared.refreshEditorRows()
        // The attention feed re-presents `.bell`, it does not own it either
        // (terminal-notch-hud.md NC-C) — see `notifyIfNeeded(for:)`'s
        // arbitration for the half that populates a feed card.
        NotchCompanionModel.shared.clearFeedItem(sessionID: sessionID)
    }

    /// A shell that exits naturally leaves its session `.exited` and its tab
    /// (or parked row) in place — coordinator decision for terminal-manager
    /// T-A: auto-closing would strand the Restart Shell affordance the
    /// exited overlay/tab still offers. No layout mutation happens here;
    /// this hook exists so later stages (T-B panel refresh, T-E attention
    /// state) have one place to react to a natural exit. The companion
    /// strip's exited-chip count re-derives here too (terminal-notch-hud.md
    /// NC-B).
    private func terminalSessionDidExit(_ sessionID: UUID, exitCode: Int32?) {
        NotchCompanionModel.shared.refreshEditorRows()
        // The manager has already applied its shared exit state. A
        // classified owner observes natural exit exactly once afterwards.
        consumeTerminalLifecycleCallback(for: sessionID)
    }

    private func consumeTerminalLifecycleCallback(for sessionID: UUID) {
        let callback = terminalLifecycleCallbacks.removeValue(forKey: sessionID)
        callback?()
    }

    private func drainTerminalLifecycleCallbacks(for sessionIDs: [UUID]? = nil) {
        let ids: [UUID]
        if let sessionIDs {
            // Close tokens already carry stable pane-tree order.
            ids = sessionIDs
        } else {
            let liveOrder = terminal.sessions.map(\.id)
            let remaining = Set(terminalLifecycleCallbacks.keys).subtracting(liveOrder)
                .sorted { $0.uuidString < $1.uuidString }
            ids = liveOrder + remaining
        }
        for sessionID in ids { consumeTerminalLifecycleCallback(for: sessionID) }
    }

    /// Shared close and teardown cleanup. A caller that passes a close token
    /// preserves its pane-tree order; teardown passes manager session order.
    private func cleanupTerminalSessions(_ sessionIDs: [UUID]) {
        for sessionID in sessionIDs {
            endCoordinatorSession(for: sessionID)
            consumeTerminalLifecycleCallback(for: sessionID)
        }
    }

    /// The terminal session id backing the FOCUSED group's selected tab,
    /// when that tab is a `.terminal` — distinct from `selectedTerminalTabID`
    /// (which returns the tab id, used by `toggleTerminal()`). Used to
    /// decide "is this session's tab focused right now" for bell/attention
    /// routing (terminal-manager.md T-E).
    private var focusedTerminalSessionID: UUID? {
        guard let group = editorLayout.group(id: editorLayout.focusedGroupID),
            let selectedTabID = group.selectedTabID,
            let tab = group.tabs.first(where: { $0.id == selectedTabID })
        else { return nil }
        switch tab.resource {
        case .terminal(let sessionID): return sessionID
        case .terminalGroup(let groupID):
            guard let paneID = terminal.terminalGroup(groupID)?.focusedPaneID else { return nil }
            return terminal.terminalController(for: paneID)?.id
        case .file, .restorable: return nil
        }
    }

    /// The one terminal row that may present as current in the terminal
    /// manager. Current follows the focused editor group's selected, visible
    /// terminal tab; it is deliberately not a second selection backed by
    /// `terminal.selectedID`. A parked terminal, a background group's terminal,
    /// or any focused file/diff/canvas therefore produces no current row.
    ///
    /// Read-only presentation seam (workbench presentation WP-30): reveal or
    /// editor focus remains the only way user interaction moves this value.
    var currentTerminalSessionID: UUID? {
        guard EditorCanvasRoute.resolve(.init(session: self)) == .editor,
            let sessionID = focusedTerminalSessionID,
            terminal.sessions.contains(where: { $0.id == sessionID })
        else { return nil }
        return sessionID
    }

    /// Frozen Wave 4 presentation seam. A group appears once in the editor
    /// layout; panes remain internal to that resource.
    var selectedTerminalGroupID: TerminalGroupID? {
        guard let group = editorLayout.group(id: editorLayout.focusedGroupID),
            let tabID = group.selectedTabID,
            let tab = group.tabs.first(where: { $0.id == tabID }),
            case .terminalGroup(let groupID) = tab.resource
        else { return nil }
        return groupID
    }

    var focusedTerminalPaneID: TerminalPaneID? {
        selectedTerminalGroupID.flatMap { terminal.terminalGroup($0)?.focusedPaneID }
    }

    var focusedTerminalSession: WorkspaceTerminalController? {
        guard let paneID = focusedTerminalPaneID else { return nil }
        return terminal.terminalController(for: paneID)
    }

    var presentedTerminalGroupIDs: Set<TerminalGroupID> {
        Set(
            editorLayout.groupIDs.flatMap { editorGroupID in
                editorLayout.group(id: editorGroupID)?.tabs.compactMap { tab in
                    guard case .terminalGroup(let groupID) = tab.resource else { return nil }
                    return groupID
                } ?? []
            })
    }

    var parkedTerminalGroupIDs: [TerminalGroupID] { terminal.parkedTerminalGroupIDs }
    /// Grouped snapshots count one committed slot each. The two temporary
    /// Ensemble compatibility callers can still own an ungrouped controller
    /// during this migration, so include only those controller IDs here.
    var liveTerminalSessionCount: Int {
        let grouped = terminal.terminalGroups.flatMap(\.panes).filter { $0.status == .live }.count
        let legacy = terminal.sessions.count { controller in
            guard terminal.terminalGroupAndPane(containing: controller.id) == nil else {
                return false
            }
            guard case .exited = controller.status else { return true }
            return false
        }
        return grouped + legacy
    }
    var retainedTerminalPaneCount: Int { terminal.retainedTerminalPaneCount }
    var isTerminalGroupStoreMutationInFlight: Bool { terminalGroupMutationTask != nil }
    var isTerminalGroupModalInputBlocked: Bool {
        pendingTerminalGroupClose != nil || pendingTerminalGroupSaveRequest != nil
            || pendingTerminalGroupRenameRequest != nil
            || pendingTerminalPaneStartingFolderRequest != nil
    }

    func terminalGroupPresentationAvailability(
        _ action: TerminalGroupPresentationAction
    ) -> TerminalGroupPresentationAvailability {
        if isTerminalGroupModalInputBlocked {
            return .init(isEnabled: false, reason: "Finish the current Terminal Group sheet first.")
        }
        if action == .toggle { return .init(isEnabled: true, reason: nil) }
        if action == .newGroup {
            guard retainedTerminalPaneCount < TerminalGroupSnapshot.maximumRetainedPanesPerWindow
            else {
                return .init(
                    isEnabled: false, reason: "The window has reached its Terminal Pane limit.")
            }
            guard liveTerminalSessionCount < TerminalGroupSnapshot.maximumPanesPerGroup else {
                return .init(
                    isEnabled: false, reason: "The window has reached its live Terminal limit.")
            }
            return .init(isEnabled: true, reason: nil)
        }
        guard let groupID = selectedTerminalGroupID,
            let group = terminal.terminalGroup(groupID)
        else { return .init(isEnabled: false, reason: "Select a Terminal Group.") }
        if isTerminalGroupStoreMutationInFlight,
            [.save, .saveAs].contains(action)
        {
            return .init(isEnabled: false, reason: "A Terminal Group save is in progress.")
        }
        let pane = group.panes.first(where: { $0.id == group.focusedPaneID })
        switch action {
        case .splitRight, .splitDown:
            guard group.panes.count < TerminalGroupSnapshot.maximumPanesPerGroup else {
                return .init(
                    isEnabled: false, reason: "This Terminal Group has reached its pane limit.")
            }
            guard retainedTerminalPaneCount < TerminalGroupSnapshot.maximumRetainedPanesPerWindow
            else {
                return .init(
                    isEnabled: false, reason: "The window has reached its Terminal Pane limit.")
            }
            guard liveTerminalSessionCount < TerminalGroupSnapshot.maximumPanesPerGroup else {
                return .init(
                    isEnabled: false, reason: "The window has reached its live Terminal limit.")
            }
            return .init(isEnabled: true, reason: nil)
        case .focus(let direction):
            return terminal.directionalPaneTarget(in: groupID, direction: direction) == nil
                ? .init(isEnabled: false, reason: "No Terminal Pane exists in that direction.")
                : .init(isEnabled: true, reason: nil)
        case .setFolder:
            guard let pane else {
                return .init(isEnabled: false, reason: "Select a Terminal Pane.")
            }
            switch pane.runtimeKind {
            case .directAgentTerminal:
                return .init(
                    isEnabled: false,
                    reason: "Agent Terminal panes cannot set a saved starting folder.")
            case .unavailableAgentTerminal:
                return .init(
                    isEnabled: false,
                    reason: "Agent Terminal profiles are not saved in this version.")
            case .ensembleRole, .ensembleCoordinator:
                return .init(
                    isEnabled: false,
                    reason: "Ensemble terminal panes cannot set a saved starting folder.")
            case .unavailableEnsemble:
                return .init(
                    isEnabled: false,
                    reason: "Ensemble terminal profiles are not saved in this version.")
            case .ordinaryShell:
                return pane.launchProfile == nil || pane.startAvailability != .available
                    ? .init(
                        isEnabled: false, reason: "This Terminal Pane has no safe starting profile."
                    )
                    : .init(isEnabled: true, reason: nil)
            }
        case .startPane:
            guard let pane else {
                return .init(isEnabled: false, reason: "Select a Terminal Pane.")
            }
            guard liveTerminalSessionCount < TerminalGroupSnapshot.maximumPanesPerGroup else {
                return .init(
                    isEnabled: false, reason: "The window has reached its live Terminal limit.")
            }
            return pane.runtimeKind == .ordinaryShell && pane.status == .stopped
                && pane.startAvailability == .available && pane.launchProfile != nil
                ? .init(isEnabled: true, reason: nil)
                : .init(
                    isEnabled: false,
                    reason: "Select a stopped ordinary-shell pane with a safe profile.")
        case .startAll:
            let candidates = group.panes.filter {
                $0.runtimeKind == .ordinaryShell && $0.launchProfile != nil
                    && $0.startAvailability == .available && $0.status == .stopped
            }
            guard !candidates.isEmpty else {
                return .init(
                    isEnabled: false, reason: "No restartable Terminal Panes are available.")
            }
            guard
                liveTerminalSessionCount + candidates.count
                    <= TerminalGroupSnapshot.maximumPanesPerGroup
            else {
                return .init(
                    isEnabled: false,
                    reason: "The restartable panes exceed the live Terminal limit.")
            }
            return .init(isEnabled: true, reason: nil)
        case .hide:
            return presentedTerminalGroupIDs.contains(groupID)
                ? .init(isEnabled: true, reason: nil)
                : .init(isEnabled: false, reason: "The Terminal Group is already hidden.")
        case .closePane:
            return pane == nil
                ? .init(isEnabled: false, reason: "Select a Terminal Pane.")
                : .init(isEnabled: true, reason: nil)
        default:
            return .init(isEnabled: true, reason: nil)
        }
    }

    /// Routes a BEL (terminal-manager.md T-E) to attention state and,
    /// opt-in, a system notification. "Not focused" = the session's tab is
    /// not the focused group's selected tab, OR the app is not active, OR
    /// its window is not key — any one of those means the user is not
    /// looking at this shell right now (`TerminalAttentionPolicy
    /// .shouldRaiseAttention`).
    private func terminalSessionDidBell(_ sessionID: UUID) {
        guard let controller = terminal.sessions.first(where: { $0.id == sessionID }) else {
            return
        }
        let shouldRaise = TerminalAttentionPolicy.shouldRaiseAttention(
            isSelectedTab: focusedTerminalSessionID == sessionID,
            isAppActive: NSApp.isActive,
            isWindowKey: controller.isHostWindowKey,
            status: controller.status
        )
        guard shouldRaise else { return }
        controller.noteBell()
        // The companion strip's resting-state attention dot re-derives
        // here too (terminal-notch-hud.md NC-B) — see
        // `terminalSessionDidClearAttention` for the clearing half.
        NotchCompanionModel.shared.refreshEditorRows()
        notifyIfNeeded(for: controller)
    }

    /// Surfaces a belling session per the `TerminalAttentionSurface`
    /// arbitration preference (terminal-notch-hud.md): the notch HUD shows
    /// synchronously (our own window — no OS gate), and/or a system
    /// notification posts when the OS has granted permission — the
    /// permission PROMPT itself is requested here, lazily, the first time
    /// a bell would actually notify (never at launch — AGENTS calm
    /// defaults). The concrete notifier (`SystemTerminalAttentionNotifier`,
    /// the only file importing `UserNotifications`) is constructed lazily
    /// too, via `resolvedAttentionNotifier()`, so a test that never reaches
    /// this path never touches `UNUserNotificationCenter` — mandatory, not
    /// stylistic, since an unsigned/test binary has no bundle identity to
    /// post through. Internal (not `private`, mirroring
    /// `processDidTerminate(exitCode:)`/`updateTitle(_:)`) so tests can
    /// drive it directly: `terminalSessionDidBell(_:)`'s own focus
    /// decision (`TerminalAttentionPolicy.shouldRaiseAttention`) depends on
    /// `NSApp.isActive`/a real key `NSWindow`, neither of which exists in
    /// `swift test`'s headless process — that pure decision is tested on
    /// its own via `TerminalAttentionPolicy`, and this covers the
    /// preference/authorization/posting behavior downstream of it.
    func notifyIfNeeded(for controller: WorkspaceTerminalController) {
        let preference = terminalAttentionSurfaceStore.surface()
        let sessionID = controller.id

        // The HUD surface (terminal-notch-hud.md): needs NO authorization —
        // it is our own window — so it shows synchronously, gated on the
        // same attention state the notification checks. The snippet is read
        // ONLY here, now that the HUD (or the companion feed) will actually
        // show it — the same single sanctioned read the notification makes,
        // passed by value and dropped on dismissal/clear (ADR 0016's
        // privacy rules, verbatim). Read exactly once, whichever surface
        // fires (terminal-notch-hud.md NC-C).
        if NotchHUDPolicy.surfaces(for: preference, authorized: false).hud,
            controller.status == .bell
        {
            let snippet = controller.recentOutputSnippet()
            // Feed-vs-drop-down arbitration (terminal-notch-hud.md NC-C,
            // "Attention"): the event lands in the companion's cross-window
            // attention feed only while the panel is pinned — a bare
            // hover-dwell peek is now just the wings pill with no downward
            // panel to route into — otherwise it spawns the separate v1
            // drop-down; a bell never produces both.
            let arbitration = CompanionHoverPolicy.companionArbitration(
                hoverState: NotchCompanionModel.shared.hoverState)
            if arbitration.routeToFeed {
                NotchCompanionModel.shared.pushFeedItem(
                    CompanionFeedItem(
                        id: UUID(),
                        sessionID: controller.id,
                        title: controller.displayName,
                        editorName: descriptor?.displayName ?? RafuBuildInformation.appName,
                        snippet: snippet,
                        timestamp: Date(),
                        color: controller.sessionColor
                    )
                )
            } else if arbitration.showDropDown {
                resolvedAttentionHUD().show(
                    NotchHUDEvent(
                        sessionID: controller.id,
                        title: controller.displayName,
                        snippet: snippet,
                        color: controller.sessionColor),
                    theme: hudThemeProvider()
                )
            }
        }

        // The notification surface keeps its lazy, first-bell authorization
        // (ADR 0016) — and the prompt is only ever requested when the
        // preference can actually post one.
        guard NotchHUDPolicy.surfaces(for: preference, authorized: true).notification
        else { return }
        let notifier = resolvedAttentionNotifier()
        Task { @MainActor [weak self, weak controller] in
            guard let self, let controller, controller.id == sessionID else { return }
            let authorized = await notifier.requestAuthorizationIfNeeded()
            let surfaces = NotchHUDPolicy.surfaces(
                for: self.terminalAttentionSurfaceStore.surface(), authorized: authorized)
            guard surfaces.notification, controller.status == .bell else { return }
            // Read ONLY here, now that the notification will actually post
            // — never from a view body. Passed by value into one
            // notification post, then dropped: never logged, persisted, or
            // transmitted anywhere else (AGENTS: the Git/AI
            // diff-transmission privacy rule extends to terminal content).
            let snippet = controller.recentOutputSnippet()
            notifier.post(
                TerminalAttentionNotification(
                    sessionID: controller.id, title: controller.displayName, body: snippet))
        }
    }

    /// Surfaces a C5 gate becoming ready through the SAME HUD/notification
    /// arbitration `notifyIfNeeded(for:)` uses for a terminal bell, but with
    /// its OWN bounded strings: the workflow name and the step name that
    /// reached the gate, and NOTHING else. Deliberately never calls
    /// `recentOutputSnippet()` or reads an artifact/prompt — a gate
    /// notification is a "come look" signal, not evidence (ADR 0018). The
    /// event carries a FRESH `UUID`, never a real terminal session id
    /// (coordinator decision): there is no live pty to reply into for a
    /// gate, so an unrecognized id simply drops reply routing silently —
    /// the same safe-by-construction fallback `TerminalAttentionCenter
    /// .deliverReply` already has for any unknown id.
    /// Whether the notch companion is currently showing this run's tile, which
    /// makes its own attention dot the signal for this gate (ADR 0016: one
    /// attention surface at a time). Reads already-live observable state — no
    /// polling, no extra work on the idle path.
    private func notchCompanionShowsActiveRun(_ runID: String) -> Bool {
        let companion = NotchCompanionModel.shared
        guard companion.preferenceStore.isEnabled() else { return false }
        return companion.activeRunItems.contains { $0.runID == runID }
    }

    func raiseConductorGateAttention(_ event: ConductorGateReadyEvent) {
        ConductorEnsembleEventCenter.shared.gateReady(event: event)
        let runName = event.workflowName
        let stepName = event.agentName
        let preference = terminalAttentionSurfaceStore.surface()
        let eventID = UUID()
        // `runName`/`stepName` come from user-authored `.rafu/agents|
        // workflows/*.md` frontmatter, capped at 1 MiB per FILE, not per
        // field (advisor D6) — bound both to a short UTF-8 prefix before
        // they ever reach a HUD event or notification body, mirroring
        // `TerminalAttentionPolicy`'s private `boundedUTF8` idiom (not
        // visible from here, so reproduced locally rather than widening
        // that type's access).
        let title = Self.boundedConductorAttentionString(runName)
        let body = "\(Self.boundedConductorAttentionString(stepName)) is ready for review."

        // ADR 0016 arbitration: when the companion strip is already showing
        // this run's progress tile, its own attention dot IS the signal — a
        // second notch drop-down for the same gate would be two surfaces
        // shouting the same thing.
        let companionShowsRun = notchCompanionShowsActiveRun(event.runID)
        if !companionShowsRun, NotchHUDPolicy.surfaces(for: preference, authorized: false).hud {
            resolvedAttentionHUD().show(
                NotchHUDEvent(sessionID: eventID, title: title, snippet: body, color: nil),
                theme: hudThemeProvider())
        }

        guard NotchHUDPolicy.surfaces(for: preference, authorized: true).notification else {
            return
        }
        let notifier = resolvedAttentionNotifier()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let authorized = await notifier.requestAuthorizationIfNeeded()
            let surfaces = NotchHUDPolicy.surfaces(
                for: self.terminalAttentionSurfaceStore.surface(), authorized: authorized)
            guard surfaces.notification else { return }
            notifier.post(
                TerminalAttentionNotification(
                    sessionID: eventID,
                    title: title,
                    body: body,
                    // Approve is offered ONLY for a `[gate:remote]` step gate;
                    // every other gate offers Open Run alone.
                    kind: .ensembleGate(
                        runID: event.runID,
                        allowsApprove: event.safeToApproveRemotely)))
        }
    }

    private func resolvedAttentionHUD() -> any NotchHUDPresenting {
        if let attentionHUD { return attentionHUD }
        let hud = NotchHUDController.shared
        attentionHUD = hud
        return hud
    }

    private func resolvedAttentionNotifier() -> any TerminalAttentionNotifying {
        if let attentionNotifier { return attentionNotifier }
        let notifier = SystemTerminalAttentionNotifier()
        attentionNotifier = notifier
        return notifier
    }

    /// Delivers a sanitized notification reply to one of THIS workspace's
    /// terminal sessions, routed here by `TerminalAttentionCenter` since a
    /// notification response arrives with no window context. Returns
    /// `true` once the session is found in this workspace — the caller
    /// stops searching other windows then, whether or not the shell was
    /// still alive to receive it (`WorkspaceTerminalController.sendReply(_:)`
    /// silently drops rather than respawning/queueing). The caller has
    /// already sanitized `text` to one control-free line under 1024 bytes
    /// (AGENTS: no shell-string interpolation — this only relays the
    /// user's own typed reply into a live pty by session UUID).
    @discardableResult
    func deliverTerminalReply(_ text: String, to sessionID: UUID) -> Bool {
        guard let controller = terminal.sessions.first(where: { $0.id == sessionID }) else {
            return false
        }
        controller.sendReply(text)
        return true
    }

    /// Renames a terminal session (terminal-manager.md T-D panel inline
    /// rename). Trims; an empty/whitespace-only or `nil` name clears back
    /// to the auto name (`reportedTitle` or the shell/index fallback). A
    /// no-op for an unknown session id.
    func renameTerminalSession(_ sessionID: UUID, to name: String?) {
        guard let controller = terminal.sessions.first(where: { $0.id == sessionID }) else {
            return
        }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        controller.userName = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Sets or clears a terminal session's color TAG (terminal-manager.md
    /// T-D). Not persisted — sessions never restore across relaunch, so
    /// neither does their color. A no-op for an unknown session id.
    func setTerminalSessionColor(_ sessionID: UUID, _ color: TerminalSessionColor?) {
        guard let controller = terminal.sessions.first(where: { $0.id == sessionID }) else {
            return
        }
        controller.sessionColor = color
    }

    /// Issue #4: the terminal presents as an ordinary editor tab (same
    /// chrome as a file tab). Hiding and closing are different verbs
    /// (terminal-manager.md T-A): ⌃`/`toggleTerminal` only removes the TAB
    /// from the layout — the session stays alive in `terminal.sessions`,
    /// parked, until revealed again, explicitly closed, or the workspace
    /// switches. `closeTerminalTab(_:)` is the one that also terminates the
    /// shell.
    func toggleTerminal() {
        guard !isTerminalGroupModalInputBlocked else { return }
        if let selectedTerminalGroupID {
            hideTerminalGroup(selectedTerminalGroupID)
        } else if let selectedTerminalTabID {
            hideTerminalTab(selectedTerminalTabID)
        } else if let parked = parkedTerminalGroupIDs.first {
            revealTerminalGroup(parked)
        } else if let parked = parkedTerminalSessions.first {
            revealTerminalSession(parked.id)
        } else {
            newTerminalTab()
        }
    }

    /// The focused group's selected tab, when it is a `.terminal` tab.
    private var selectedTerminalTabID: EditorTabID? {
        guard let group = editorLayout.group(id: editorLayout.focusedGroupID),
            let selectedTabID = group.selectedTabID,
            let tab = group.tabs.first(where: { $0.id == selectedTabID }),
            case .terminal = tab.resource
        else { return nil }
        return tab.id
    }

    /// Creates one lazy ordinary-shell pane in one compound outer editor tab.
    /// The profile holds a normalized workspace-relative path; it never reads
    /// a shell's live working directory.
    func newTerminalGroup(shell: TerminalShell? = nil) {
        guard !isTerminalGroupModalInputBlocked else { return }
        installTerminalHandlersIfNeeded()
        // Unit-level and migration callers can create a session before a
        // workspace descriptor exists. Keep their historical home-directory
        // fallback while still making the runtime an ordinary Terminal Group.
        let rootURL = rootURL ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let folder = terminalFolder(for: preferredTerminalDirectory()) ?? .root
        let resolvedShell = shell ?? preferredTerminalShell()
        if let shell { preferredShellStore.record(shell) }
        let profile = TerminalPaneLaunchProfile(
            shell: TerminalPaneShellChoice(approvedShellPath: resolvedShell.path)
                ?? .preferredShell,
            startingFolder: folder)
        do {
            let group = try terminal.createLiveGroup(
                instantiation: .ordinaryShell(
                    startingDirectory: resolvedTerminalDirectory(folder, rootURL: rootURL),
                    shell: resolvedShell,
                    profile: profile))
            revealTerminalGroup(group.id)
        } catch {
            presentTerminalGroupError(error.localizedDescription)
        }
    }

    /// Source-compatible entry point that creates a one-pane Terminal Group.
    func newTerminalTab(shell: TerminalShell? = nil) {
        newTerminalGroup(shell: shell)
    }

    func splitFocusedTerminalPane(_ placement: TerminalGroupSplitPlacement) {
        guard !isTerminalGroupModalInputBlocked else { return }
        guard let groupID = selectedTerminalGroupID,
            let group = terminal.terminalGroup(groupID),
            let focused = group.panes.first(where: { $0.id == group.focusedPaneID }),
            let rootURL
        else { return }
        let profile: TerminalPaneLaunchProfile
        if focused.runtimeKind == .ordinaryShell,
            focused.startAvailability == .available,
            let safeProfile = focused.launchProfile
        {
            profile = safeProfile
        } else {
            // Classified and unavailable panes never donate a profile. Their
            // split is a fresh ordinary shell at the bounded workspace root.
            profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
        }
        guard
            terminalFolder(for: resolvedTerminalDirectory(profile.startingFolder, rootURL: rootURL))
                != nil,
            let shell = resolvedShell(for: profile.shell)
        else {
            presentTerminalGroupError("The saved terminal profile is no longer available.")
            return
        }
        do {
            _ = try terminal.splitFocusedPane(
                in: groupID, placement: placement,
                instantiation: .ordinaryShell(
                    startingDirectory: resolvedTerminalDirectory(
                        profile.startingFolder, rootURL: rootURL),
                    shell: shell, profile: profile))
            if let newPaneID = terminal.terminalGroup(groupID)?.focusedPaneID {
                focusTerminalPane(newPaneID, in: groupID)
            }
            persistWorkspaceState()
        } catch { presentTerminalGroupError(error.localizedDescription) }
    }

    func focusTerminalPane(_ paneID: TerminalPaneID, in groupID: TerminalGroupID) {
        do {
            _ = try terminal.perform(.focusPane(groupID: groupID, paneID: paneID))
            terminal.selectedID = terminal.terminalController(for: paneID)?.id
            terminal.terminalController(for: paneID)?.clearAttention()
            terminalGroupFocusRequest &+= 1
        } catch { presentTerminalGroupError(error.localizedDescription) }
    }

    func focusTerminalPane(_ direction: TerminalPaneFocusDirection) {
        guard !isTerminalGroupModalInputBlocked else { return }
        guard let groupID = selectedTerminalGroupID else { return }
        do {
            _ = try terminal.perform(.focusDirection(groupID: groupID, direction: direction))
            if let paneID = terminal.terminalGroup(groupID)?.focusedPaneID {
                focusTerminalPane(paneID, in: groupID)
            }
        } catch { presentTerminalGroupError(error.localizedDescription) }
    }

    func terminalPaneFocusTarget(_ direction: TerminalPaneFocusDirection) -> TerminalPaneID? {
        guard let groupID = selectedTerminalGroupID else { return nil }
        return terminal.directionalPaneTarget(in: groupID, direction: direction)
    }

    func renameTerminalGroup(_ groupID: TerminalGroupID, to rawName: String) {
        do {
            try terminal.renameTerminalGroup(groupID, rawName: rawName)
            persistWorkspaceState()
        } catch { presentTerminalGroupError(error.localizedDescription) }
    }

    func requestTerminalGroupRename(_ groupID: TerminalGroupID) {
        guard !isTerminalGroupModalInputBlocked,
            let group = terminal.terminalGroup(groupID)
        else { return }
        pendingTerminalGroupRenameRequest = TerminalGroupRenameRequest(
            id: groupID, proposedName: group.name.rawValue)
    }

    func updatePendingTerminalGroupRename(_ name: String) {
        pendingTerminalGroupRenameRequest?.proposedName = name
    }

    func cancelPendingTerminalGroupRename() { pendingTerminalGroupRenameRequest = nil }

    func completePendingTerminalGroupRename() {
        guard let request = pendingTerminalGroupRenameRequest else { return }
        pendingTerminalGroupRenameRequest = nil
        renameTerminalGroup(request.id, to: request.proposedName)
    }

    func setTerminalPaneStartingFolder(_ paneID: TerminalPaneID, to directory: URL) {
        guard let folder = terminalFolder(for: directory.path) else {
            presentTerminalGroupError(
                "The Terminal Group folder must be a readable directory inside this workspace.")
            return
        }
        do {
            _ = try terminal.perform(.setPaneStartingFolder(paneID: paneID, folder: folder))
            persistWorkspaceState()
        } catch { presentTerminalGroupError(error.localizedDescription) }
    }

    func requestTerminalPaneStartingFolder(_ paneID: TerminalPaneID) {
        guard !isTerminalGroupModalInputBlocked,
            rootURL != nil,
            let groupID = terminal.terminalGroup(containing: paneID),
            let pane = terminal.terminalGroup(groupID)?.panes.first(where: { $0.id == paneID }),
            pane.runtimeKind == .ordinaryShell,
            pane.launchProfile != nil, pane.startAvailability == .available
        else { return }
        let initialDirectory = rootURL.map { root in
            root.appending(path: pane.launchProfile?.startingFolder.rawValue ?? "")
        }
        pendingTerminalPaneStartingFolderRequest = TerminalPaneStartingFolderRequest(
            id: paneID, initialDirectory: initialDirectory)
    }

    func cancelPendingTerminalPaneStartingFolder() {
        pendingTerminalPaneStartingFolderRequest = nil
    }

    func completePendingTerminalPaneStartingFolder(_ directory: URL) {
        guard let request = pendingTerminalPaneStartingFolderRequest else { return }
        pendingTerminalPaneStartingFolderRequest = nil
        setTerminalPaneStartingFolder(request.id, to: directory)
    }

    func setTerminalDividerFraction(_ splitID: TerminalGroupSplitID, to fraction: Double) {
        do {
            _ = try terminal.perform(.setDividerFraction(splitID: splitID, fraction: fraction))
            persistWorkspaceState()
        } catch { presentTerminalGroupError(error.localizedDescription) }
    }

    func performTerminalGroupViewAction(_ action: TerminalGroupViewAction) {
        switch action {
        case .focus(let paneID):
            guard let groupID = terminal.terminalGroup(containing: paneID) else { return }
            focusTerminalPane(paneID, in: groupID)
        case .setDividerFraction(let splitID, let fraction):
            setTerminalDividerFraction(splitID, to: fraction)
        case .close(let paneID): closeTerminalPane(paneID)
        case .restart(let paneID): restartTerminalPane(paneID)
        case .start(let paneID): startTerminalPane(paneID)
        }
    }

    func startTerminalPane(_ paneID: TerminalPaneID) {
        guard let groupID = terminal.terminalGroup(containing: paneID),
            let pane = terminal.terminalGroup(groupID)?.panes.first(where: { $0.id == paneID }),
            let profile = pane.launchProfile,
            let rootURL,
            terminalFolder(for: resolvedTerminalDirectory(profile.startingFolder, rootURL: rootURL))
                != nil,
            let shell = resolvedShell(for: profile.shell)
        else {
            presentTerminalGroupError("The saved terminal folder is no longer available.")
            return
        }
        do {
            // The ordinary-shell transaction validates and reserves live
            // capacity atomically. TG-20 reservations are process-only.
            _ = try terminal.startPane(
                paneID,
                instantiation: .ordinaryShell(
                    startingDirectory: resolvedTerminalDirectory(
                        profile.startingFolder, rootURL: rootURL),
                    shell: shell, profile: profile))
            revealTerminalGroup(groupID)
            terminalGroupFocusRequest &+= 1
        } catch { presentTerminalGroupError(error.localizedDescription) }
    }

    func restartTerminalPane(_ paneID: TerminalPaneID) {
        guard let groupID = terminal.terminalGroup(containing: paneID),
            let pane = terminal.terminalGroup(groupID)?.panes.first(where: { $0.id == paneID }),
            let profile = pane.launchProfile,
            let rootURL,
            terminalFolder(for: resolvedTerminalDirectory(profile.startingFolder, rootURL: rootURL))
                != nil,
            resolvedShell(for: profile.shell) != nil
        else {
            presentTerminalGroupError("The saved terminal profile is no longer available.")
            return
        }
        do {
            try terminal.restartExitedPane(paneID)
            terminalGroupFocusRequest &+= 1
        } catch { presentTerminalGroupError(error.localizedDescription) }
    }

    /// Starts the stopped ordinary-shell panes only after folder, shell, and
    /// capacity preflight for every target. Individual external process
    /// startup remains non-transactional after this manager transaction.
    func startAllRestartableTerminalPanes(in groupID: TerminalGroupID) {
        guard let snapshot = terminal.terminalGroup(groupID), let rootURL else { return }
        let restartable = snapshot.panes.filter {
            $0.startAvailability == .available && ($0.status == .stopped || $0.status == .exited)
        }
        guard !restartable.isEmpty else { return }
        var instantiations: [TerminalPaneID: TerminalGroupControllerInstantiation] = [:]
        for pane in restartable {
            guard let profile = pane.launchProfile,
                terminalFolder(
                    for: resolvedTerminalDirectory(profile.startingFolder, rootURL: rootURL))
                    != nil,
                let shell = resolvedShell(for: profile.shell)
            else {
                presentTerminalGroupError("A saved terminal profile is no longer available.")
                return
            }
            if pane.status == .stopped {
                instantiations[pane.id] = .ordinaryShell(
                    startingDirectory: resolvedTerminalDirectory(
                        profile.startingFolder, rootURL: rootURL),
                    shell: shell, profile: profile)
            }
        }
        do {
            _ = try terminal.startAllRestartablePanes(
                in: groupID, instantiations: instantiations)
            revealTerminalGroup(groupID)
            terminalGroupFocusRequest &+= 1
        } catch { presentTerminalGroupError(error.localizedDescription) }
    }

    func closeTerminalPane(_ paneID: TerminalPaneID) {
        guard !isTerminalGroupModalInputBlocked else { return }
        guard let groupID = terminal.terminalGroup(containing: paneID),
            let snapshot = terminal.terminalGroup(groupID)
        else { return }
        // The last pane closes the complete outer resource. This preserves
        // one group-level live-process confirmation rather than silently
        // treating a terminal tab close as a pane-only operation.
        if snapshot.panes.count == 1 {
            requestTerminalGroupClose(.group(groupID), requiresConfirmation: true)
        } else {
            requestTerminalGroupClose(.pane(paneID), requiresConfirmation: false)
        }
    }

    func requestTerminalGroupClose(_ groupID: TerminalGroupID) {
        guard !isTerminalGroupModalInputBlocked else { return }
        requestTerminalGroupClose(.group(groupID), requiresConfirmation: true)
    }

    func cancelTerminalGroupClose() { pendingTerminalGroupClose = nil }

    func confirmTerminalGroupClose() {
        guard let pending = pendingTerminalGroupClose else { return }
        do {
            let affectedGroupID: TerminalGroupID? =
                switch pending.target {
                case .group(let groupID): groupID
                case .pane(let paneID): terminal.terminalGroup(containing: paneID)
                }
            let effect = try terminal.perform(.prepareClose(pending.target))
            guard case .requestCloseConfirmation(let fresh) = effect, fresh == pending else {
                if case .requestCloseConfirmation(let fresh) = effect {
                    pendingTerminalGroupClose = nil
                    Task { @MainActor [weak self] in
                        await Task.yield()
                        guard let self, self.pendingTerminalGroupClose == nil else { return }
                        self.pendingTerminalGroupClose = fresh
                        self.terminalGroupClosePresentationRevision &+= 1
                        self.terminalGroupCloseRepreparedForTesting?()
                    }
                }
                return
            }
            cleanupTerminalSessions(fresh.affectedSessionIDs)
            _ = try terminal.perform(.finalizeClose(fresh))
            if let affectedGroupID, terminal.terminalGroup(affectedGroupID) == nil {
                removeTerminalGroupTab(affectedGroupID)
            }
            synchronizeSelectionFromLayout()
            pendingTerminalGroupClose = nil
            persistWorkspaceState()
        } catch {
            pendingTerminalGroupClose = nil
            presentTerminalGroupError(error.localizedDescription)
        }
    }

    private func requestTerminalGroupClose(
        _ target: TerminalGroupCloseTarget, requiresConfirmation: Bool
    ) {
        do {
            let effect = try terminal.perform(.prepareClose(target))
            guard case .requestCloseConfirmation(let token) = effect else { return }
            if requiresConfirmation && token.liveProcessCount > 0 {
                pendingTerminalGroupClose = token
            } else {
                pendingTerminalGroupClose = token
                confirmTerminalGroupClose()
            }
        } catch { presentTerminalGroupError(error.localizedDescription) }
    }

    func hideTerminalGroup(_ groupID: TerminalGroupID) {
        do {
            _ = try terminal.perform(.parkGroup(groupID))
            removeTerminalGroupTab(groupID)
            synchronizeSelectionFromLayout()
            persistWorkspaceState()
        } catch { presentTerminalGroupError(error.localizedDescription) }
    }

    func revealTerminalGroup(_ groupID: TerminalGroupID) {
        guard terminal.terminalGroup(groupID) != nil else { return }
        do { _ = try terminal.perform(.revealGroup(groupID)) } catch {
            presentTerminalGroupError(error.localizedDescription)
            return
        }
        // Terminal Groups occupy the same editor canvas slot as run detail,
        // graph, Ensemble creation, and Settings. Keep the Runs selection so
        // the panel remains stable while a terminal replaces its canvas.
        conductorRunCanvasID = nil
        conductorGraphVisible = false
        if !ensembleStartLaunchInProgress {
            ensembleStartCanvasVisible = false
        }
        ensembleNewRunCanvasVisible = false
        settingsVisible = false
        if let tab = editorLayout.tab(matching: .terminalGroup(groupID: groupID)),
            let editorGroupID = editorLayout.group(containing: tab.id)?.id
        {
            editorLayout.select(tab.id, in: editorGroupID)
        } else {
            let tab = EditorTabState(resource: .terminalGroup(groupID: groupID))
            editorLayout.insert(tab, in: editorLayout.focusedGroupID)
            editorLayout.select(tab.id, in: editorLayout.focusedGroupID)
        }
        selectedDocumentID = nil
        selectedTreePath = nil
        if let paneID = terminal.terminalGroup(groupID)?.focusedPaneID {
            focusTerminalPane(paneID, in: groupID)
        }
        persistWorkspaceState()
    }

    /// Hides one terminal tab: removes it from the editor layout but leaves
    /// its session running, parked in `terminal.sessions`
    /// (terminal-manager.md T-A — the ⌃` "toggle away" half of hide-vs-close).
    /// A no-op if `tabID` does not resolve to a live `.terminal` tab. Does
    /// not touch `terminal.selectedID` directly;
    /// `synchronizeSelectionFromLayout()` only updates it when the newly
    /// focused tab is itself a terminal.
    func hideTerminalTab(_ tabID: EditorTabID) {
        guard let groupID = editorLayout.group(containing: tabID)?.id,
            let tab = editorLayout.group(id: groupID)?.tabs.first(where: { $0.id == tabID }),
            case .terminal(let sessionID) = tab.resource
        else { return }
        _ = editorLayout.closeTab(tabID)
        terminal.notePark(sessionID)
        synchronizeSelectionFromLayout()
        persistWorkspaceState()
    }

    /// Closes one terminal tab: removes it from the editor layout AND
    /// terminates its shell (`terminal.close(_:)`), so a closed terminal tab
    /// never leaves an orphaned process running. A no-op if `tabID` does not
    /// resolve to a live `.terminal` tab. See `hideTerminalTab(_:)` for the
    /// park-without-killing sibling used by ⌃`/`toggleTerminal`. Any future
    /// generic layout-close path (close-others, close-all — neither exists
    /// today) that may touch a `.terminal` tab must route through this
    /// method or `hideTerminalTab(_:)` rather than calling
    /// `editorLayout.closeTab(_:)` directly, to keep hide-vs-close an
    /// explicit decision instead of an accidental orphaned process.
    func closeTerminalTab(_ tabID: EditorTabID) {
        guard let groupID = editorLayout.group(containing: tabID)?.id,
            let tab = editorLayout.group(id: groupID)?.tabs.first(where: { $0.id == tabID }),
            case .terminal(let sessionID) = tab.resource
        else { return }
        _ = editorLayout.closeTab(tabID)
        endCoordinatorSession(for: sessionID)
        terminal.close(sessionID)
        synchronizeSelectionFromLayout()
        persistWorkspaceState()
    }

    /// Removes a terminal session outright: drops its tab if it currently
    /// has one anywhere in the layout, then terminates its shell. Used for
    /// parked/exited sessions that have no tab to close through
    /// `closeTerminalTab(_:)` — e.g. the future T-B sessions panel. A no-op
    /// for an unknown session id.
    func closeTerminalSession(_ sessionID: UUID) {
        guard terminal.sessions.contains(where: { $0.id == sessionID }) else { return }
        if let (_, paneID) = terminal.terminalGroupAndPane(containing: sessionID) {
            closeTerminalPane(paneID)
            return
        }
        if let tab = editorLayout.tab(matching: .terminal(sessionID: sessionID)) {
            _ = editorLayout.closeTab(tab.id)
        }
        endCoordinatorSession(for: sessionID)
        terminal.close(sessionID)
        synchronizeSelectionFromLayout()
        persistWorkspaceState()
    }

    /// Hides a session's tab if it has one, leaving the shell alive and parked
    /// — the session-id counterpart to `hideTerminalTab(_:)`, used by the
    /// terminals panel, which knows session ids and not `EditorTabID`s. A
    /// no-op for an unknown or already-parked session.
    func hideTerminalSession(_ sessionID: UUID) {
        if let (groupID, _) = terminal.terminalGroupAndPane(containing: sessionID) {
            hideTerminalGroup(groupID)
            return
        }
        guard let tab = editorLayout.tab(matching: .terminal(sessionID: sessionID)) else { return }
        hideTerminalTab(tab.id)
    }

    var agentTerminalSheetPresented: Bool = false

    func presentAgentTerminalSheet() {
        guard descriptor != nil else { return }
        agentTerminalSheetPresented = true
    }

    func openAgentTerminal(spec: TerminalProcessSpec) {
        installTerminalHandlersIfNeeded()
        guard let provider = spec.agentProvider else {
            presentTerminalGroupError("The Agent Terminal did not include a provider identity.")
            return
        }
        do {
            _ = try insertClassifiedTerminalSession(
                spec: spec, kind: .directAgentTerminal(provider: provider), lifecycle: {})
        } catch { presentTerminalGroupError(error.localizedDescription) }
    }

    /// Frozen TG-42 insertion boundary. Capacity fails before a controller is
    /// returned, and the caller never receives manager/tree mutation access.
    @discardableResult
    func insertClassifiedTerminalSession(
        spec: TerminalProcessSpec,
        kind: TerminalPaneRuntimeKind,
        lifecycle: @escaping @MainActor () -> Void,
        reservation suppliedReservation: TerminalGroupCapacityReservation? = nil
    ) throws -> UUID {
        installTerminalHandlersIfNeeded()
        let reservation = try suppliedReservation ?? terminal.reserveLiveSessionCapacity(1)
        let group: TerminalGroupSnapshot
        do {
            group = try terminal.createLiveGroup(
                instantiation: .process(spec: spec, kind: kind), reservation: reservation)
            // Internal direct-Agent reservations are fully acknowledged here.
            // A coordinator-provided reservation remains committed until that
            // caller explicitly consumes it through the frozen wrapper.
            if suppliedReservation == nil { try terminal.consumeLiveSessionCapacity(reservation) }
        } catch {
            try? terminal.cancelLiveSessionCapacity(reservation)
            throw error
        }
        guard let sessionID = group.panes.first?.sessionID else {
            throw TerminalGroupValidationError.unsupportedPaneStart
        }
        terminalLifecycleCallbacks[sessionID] = lifecycle
        revealTerminalGroup(group.id)
        return sessionID
    }

    /// The owner already performed its run-state transition. Remove the
    /// callback and close the classified pane without invoking it again.
    func ownerHandledTerminalLifecycleClose(_ sessionID: UUID) {
        terminalLifecycleCallbacks.removeValue(forKey: sessionID)
        guard let (groupID, paneID) = terminal.terminalGroupAndPane(containing: sessionID) else {
            return
        }
        let target: TerminalGroupCloseTarget =
            terminal.terminalGroup(groupID)?.panes.count == 1 ? .group(groupID) : .pane(paneID)
        do {
            let effect = try terminal.perform(.prepareClose(target))
            guard case .requestCloseConfirmation(let token) = effect else { return }
            _ = try terminal.perform(.finalizeClose(token))
            if terminal.terminalGroup(groupID) == nil { removeTerminalGroupTab(groupID) }
            synchronizeSelectionFromLayout()
            persistWorkspaceState()
        } catch { presentTerminalGroupError(error.localizedDescription) }
    }

    func reserveTerminalLiveSessionCapacity(_ count: Int) throws -> TerminalGroupCapacityReservation
    {
        try terminal.reserveLiveSessionCapacity(count)
    }

    func consumeTerminalLiveSessionCapacity(_ reservation: TerminalGroupCapacityReservation) throws
    {
        try terminal.consumeLiveSessionCapacity(reservation)
    }

    func cancelTerminalLiveSessionCapacity(_ reservation: TerminalGroupCapacityReservation) throws {
        try terminal.cancelLiveSessionCapacity(reservation)
    }

    /// Reveals a terminal session as a tab: selects its existing tab if it
    /// already has one anywhere in the layout (never duplicates), otherwise
    /// inserts a fresh tab for it into the focused group and selects that.
    /// Matches `newTerminalTab()`'s existing tab-selection behavior — clears
    /// file selection, selects the session in `terminal`. A no-op for an
    /// unknown session id.
    func revealTerminalSession(_ sessionID: UUID) {
        guard terminal.sessions.contains(where: { $0.id == sessionID }) else { return }
        if let (groupID, _) = terminal.terminalGroupAndPane(containing: sessionID) {
            revealTerminalGroup(groupID)
            return
        }
        // Old restoration and Ensemble callers can still reach a legacy
        // controller. Adopt it atomically before it becomes visible so a
        // session UUID and its process remain continuous through migration.
        do {
            let group = try terminal.adoptUngroupedSession(sessionID)
            revealTerminalGroup(group.id)
        } catch {
            presentTerminalGroupError(error.localizedDescription)
        }
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

    private func terminalFolder(for path: String) -> TerminalWorkspaceRelativePath? {
        guard let rootURL else { return nil }
        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let candidate = URL(fileURLWithPath: path, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
            isDirectory.boolValue,
            FileManager.default.isReadableFile(atPath: candidate.path)
        else { return nil }
        let rootPath = root.path
        let candidatePath = candidate.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            return nil
        }
        let relative = String(candidatePath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return TerminalWorkspaceRelativePath(relative)
    }

    private func resolvedTerminalDirectory(
        _ folder: TerminalWorkspaceRelativePath, rootURL: URL
    ) -> String {
        rootURL.appending(path: folder.rawValue).standardizedFileURL.path
    }

    private func resolvedShell(for choice: TerminalPaneShellChoice) -> TerminalShell? {
        switch choice {
        case .preferredShell: preferredTerminalShell()
        case .approvedShellPath(let path):
            availableTerminalShells.first(where: { $0.path == path })
        }
    }

    private func removeTerminalGroupTab(for target: TerminalGroupCloseTarget) {
        let groupID: TerminalGroupID?
        switch target {
        case .group(let value): groupID = value
        case .pane(let paneID): groupID = terminal.terminalGroup(containing: paneID)
        }
        guard let groupID,
            let tab = editorLayout.tab(matching: .terminalGroup(groupID: groupID))
        else { return }
        _ = editorLayout.closeTab(tab.id)
    }

    private func removeTerminalGroupTab(_ groupID: TerminalGroupID) {
        guard let tab = editorLayout.tab(matching: .terminalGroup(groupID: groupID)) else { return }
        _ = editorLayout.closeTab(tab.id)
    }

    private func presentTerminalGroupError(_ message: String) {
        openFolderErrorTitle = "Terminal Group"
        openFolderErrorMessage = String(decoding: message.utf8.prefix(512), as: UTF8.self)
        isOpenFolderErrorPresented = true
    }

    private func clearTerminalGroupPresentationRequests() {
        terminalGroupSavePresentationEpoch &+= 1
        isPendingTerminalGroupSaveSubmission = false
        pendingTerminalGroupSaveRequest = nil
        pendingTerminalGroupRenameRequest = nil
        pendingTerminalPaneStartingFolderRequest = nil
    }

    private func finishPendingTerminalGroupSaveSubmission(
        groupID: TerminalGroupID, presentationEpoch: UInt64?, succeeded: Bool = true,
        errorMessage: String? = nil
    ) {
        guard let presentationEpoch,
            terminalGroupSavePresentationEpoch == presentationEpoch,
            pendingTerminalGroupSaveRequest?.id == groupID
        else { return }
        isPendingTerminalGroupSaveSubmission = false
        if succeeded {
            pendingTerminalGroupSaveRequest = nil
        } else if let errorMessage {
            terminalGroupStoreError = String(
                decoding: errorMessage.utf8.prefix(512), as: UTF8.self)
        }
    }

    // MARK: - Saved Terminal Group library

    private func resolvedTerminalGroupSavedLayoutStore() async
        -> any TerminalGroupSavedLayoutStoring
    {
        if let terminalGroupSavedLayoutStore { return terminalGroupSavedLayoutStore }
        return await TerminalGroupSavedLayoutStore.shared()
    }

    private func beginTerminalGroupLibrary(for rootURL: URL) {
        endTerminalGroupLibrary()
        terminalGroupWorkspaceGeneration &+= 1
        if terminalGroupWorkspaceGeneration == 0 { terminalGroupWorkspaceGeneration = 1 }
        let generation = terminalGroupWorkspaceGeneration
        let key = TerminalGroupWorkspaceKey(
            standardizedRoot: rootURL.resolvingSymlinksInPath().standardizedFileURL)
        let injectedStore = terminalGroupSavedLayoutStore
        // Subscribe before requesting the first list. The actor yields its
        // current revision before returning the stream, which seals the
        // subscribe/list mutation race between workspace windows.
        terminalGroupChangeTask = Task { [weak self, injectedStore] in
            let store: any TerminalGroupSavedLayoutStoring
            if let injectedStore {
                store = injectedStore
            } else {
                store = await TerminalGroupSavedLayoutStore.shared()
            }
            let changes = await store.changes(for: key)
            // `changes` returns only after it registered the continuation.
            // Its current revision is the first element, so this first list
            // cannot race ahead of subscription registration.
            for await _ in changes {
                guard !Task.isCancelled, let self,
                    self.terminalGroupWorkspaceGeneration == generation
                else { return }
                self.loadTerminalGroupLibrary(key: key, generation: generation)
            }
        }
    }

    // MARK: - Terminal Group integration-test synchronization

    /// Starts the same per-window library binding used by workspace open.
    /// This deliberately exposes no manager mutation: integration tests only
    /// use it to inject an isolated saved-layout actor and await its stream.
    func beginTerminalGroupLibraryForTesting() {
        guard let rootURL else { return }
        beginTerminalGroupLibrary(for: rootURL)
    }

    /// Waits for the current list or mutation operation, if one exists. The
    /// long-lived change subscription is intentionally not awaited here.
    func waitForTerminalGroupStoreOperationForTesting() async {
        await terminalGroupStoreTask?.value
        await terminalGroupMutationTask?.value
    }

    /// Exercises the restoration insertion boundary without bookmark or file
    /// watcher setup. Production restoration still calls the private method.
    func restoreTerminalGroupInstancesForTesting(
        _ restoration: TerminalGroupWorkspaceRestoration
    ) async {
        guard let rootURL else { return }
        await restoreTerminalGroupInstances(restoration, rootURL: rootURL)
    }

    /// Read-only persistence seam for the two-window detachment regression.
    /// It returns the same inert envelope that normal workspace persistence
    /// would encode and cannot modify the live editor layout.
    func terminalGroupWorkspaceRestorationForTesting() -> TerminalGroupWorkspaceRestoration? {
        terminalGroupWorkspaceRestoration()
    }

    /// Exercises layout repair after inert-group insertion without bookmark
    /// or file-watcher setup. It is read-only outside the session layout.
    func restoreEditorLayoutForTesting(
        _ restoration: EditorLayoutRestoration,
        terminalGroups: TerminalGroupWorkspaceRestoration,
        rootURL: URL
    ) {
        restoreEditorLayout(
            restoration, terminalGroups: terminalGroups,
            from: rootURL.path, to: rootURL)
        synchronizeSelectionFromLayout()
    }

    private func endTerminalGroupLibrary() {
        terminalGroupWorkspaceGeneration &+= 1
        if terminalGroupWorkspaceGeneration == 0 { terminalGroupWorkspaceGeneration = 1 }
        terminalGroupStoreTask?.cancel()
        terminalGroupStoreTask = nil
        terminalGroupChangeTask?.cancel()
        terminalGroupChangeTask = nil
        terminalGroupMutationTask?.cancel()
        terminalGroupMutationTask = nil
        clearTerminalGroupPresentationRequests()
        terminalGroupMutationEpoch &+= 1
        savedTerminalGroups = []
        terminalGroupStoreError = nil
        terminalGroupRestorationError = nil
    }

    private func loadTerminalGroupLibrary(
        key: TerminalGroupWorkspaceKey, generation: UInt64
    ) {
        terminalGroupStoreTask?.cancel()
        terminalGroupListEpoch &+= 1
        let epoch = terminalGroupListEpoch
        terminalGroupStoreTask = Task { [weak self] in
            do {
                guard let self else { return }
                let store = await self.resolvedTerminalGroupSavedLayoutStore()
                let records = try await store.listSavedLayouts(for: key)
                guard !Task.isCancelled,
                    self.terminalGroupWorkspaceGeneration == generation,
                    self.terminalGroupListEpoch == epoch
                else {
                    self.terminalGroupListFinishedForTesting?(epoch)
                    return
                }
                self.savedTerminalGroups = records
                self.terminalGroupStoreError = self.terminalGroupRestorationError
                let existing = Set(records.map(\.id))
                var detachedSavedLayout = false
                for snapshot in self.terminal.terminalGroups {
                    if let savedID = snapshot.savedLayoutID, !existing.contains(savedID) {
                        if (try? self.terminal.perform(.detachDeletedSavedLayout(savedID))) != nil {
                            detachedSavedLayout = true
                        }
                    }
                }
                if detachedSavedLayout { self.persistWorkspaceState() }
                self.terminalGroupListFinishedForTesting?(epoch)
            } catch {
                guard let self else { return }
                guard !Task.isCancelled,
                    self.terminalGroupWorkspaceGeneration == generation,
                    self.terminalGroupListEpoch == epoch
                else {
                    self.terminalGroupListFinishedForTesting?(epoch)
                    return
                }
                self.terminalGroupStoreError = String(
                    decoding: error.localizedDescription.utf8.prefix(512), as: UTF8.self)
                self.terminalGroupListFinishedForTesting?(epoch)
            }
        }
    }

    func openSavedTerminalGroup(_ savedLayoutID: SavedTerminalGroupID) {
        guard let rootURL,
            let record = savedTerminalGroups.first(where: { $0.id == savedLayoutID })
        else { return }
        do {
            let decoded = try terminalGroupCodec(for: rootURL).openNamedLayout(record)
            let group = try terminal.insertInertSnapshot(decoded.snapshot)
            revealTerminalGroup(group.id)
        } catch { presentTerminalGroupError(error.localizedDescription) }
    }

    func deleteSavedTerminalGroup(_ savedLayoutID: SavedTerminalGroupID) {
        guard let rootURL, terminalGroupMutationTask == nil else { return }
        let key = TerminalGroupWorkspaceKey(standardizedRoot: rootURL)
        let generation = terminalGroupWorkspaceGeneration
        terminalGroupMutationEpoch &+= 1
        let epoch = terminalGroupMutationEpoch
        terminalGroupMutationTask = Task { [weak self] in
            do {
                guard let self else { return }
                let store = await self.resolvedTerminalGroupSavedLayoutStore()
                _ = try await store.deleteSavedLayout(
                    TerminalGroupSavedLayoutDeleteRequest(
                        workspaceKey: key, savedLayoutID: savedLayoutID))
                guard !Task.isCancelled,
                    self.terminalGroupWorkspaceGeneration == generation,
                    self.terminalGroupMutationEpoch == epoch
                else { return }
                _ = try self.terminal.perform(.detachDeletedSavedLayout(savedLayoutID))
                self.terminalGroupMutationTask = nil
                self.loadTerminalGroupLibrary(key: key, generation: generation)
                self.persistWorkspaceState()
            } catch {
                guard let self, !Task.isCancelled,
                    self.terminalGroupWorkspaceGeneration == generation,
                    self.terminalGroupMutationEpoch == epoch
                else { return }
                self.terminalGroupMutationTask = nil
                self.terminalGroupStoreError = String(
                    decoding: error.localizedDescription.utf8.prefix(512), as: UTF8.self)
            }
        }
    }

    /// Save uses the open instance only as a snapshot source. It never
    /// replaces its live pane tree with data read from the named library.
    func requestTerminalGroupSave(_ groupID: TerminalGroupID) {
        guard !isTerminalGroupModalInputBlocked, terminalGroupMutationTask == nil,
            let snapshot = terminal.terminalGroup(groupID)
        else {
            return
        }
        if snapshot.savedLayoutID != nil {
            saveTerminalGroup(groupID)
        } else {
            // Command-S first tries the current bounded group name. Only a
            // store conflict needs the Save As-style naming sheet.
            saveTerminalGroup(
                snapshot, groupID: groupID, name: snapshot.name, operation: .firstSave,
                presentNameRequestOnConflict: true)
        }
    }

    func requestTerminalGroupSaveAs(_ groupID: TerminalGroupID) {
        guard !isTerminalGroupModalInputBlocked, terminalGroupMutationTask == nil,
            let snapshot = terminal.terminalGroup(groupID)
        else {
            return
        }
        terminalGroupStoreError = nil
        terminalGroupSavePresentationEpoch &+= 1
        pendingTerminalGroupSaveRequest = TerminalGroupSaveRequest(
            id: groupID, kind: .saveAs, proposedName: snapshot.name.rawValue)
    }

    func updatePendingTerminalGroupSaveName(_ name: String) {
        guard !isPendingTerminalGroupSaveSubmission else { return }
        pendingTerminalGroupSaveRequest?.proposedName = name
    }

    func cancelPendingTerminalGroupSave() {
        guard !isPendingTerminalGroupSaveSubmission else { return }
        terminalGroupSavePresentationEpoch &+= 1
        pendingTerminalGroupSaveRequest = nil
    }

    func completePendingTerminalGroupSave() {
        guard let request = pendingTerminalGroupSaveRequest,
            !isPendingTerminalGroupSaveSubmission
        else { return }
        isPendingTerminalGroupSaveSubmission = true
        terminalGroupStoreError = nil
        let operation: TerminalGroupSavedLayoutSaveOperation =
            request.kind == .firstSave ? .firstSave : .saveAs
        saveTerminalGroupAs(
            request.id, name: request.proposedName, operation: operation,
            pendingPresentationEpoch: terminalGroupSavePresentationEpoch)
    }

    func saveTerminalGroup(_ groupID: TerminalGroupID) {
        guard let snapshot = terminal.terminalGroup(groupID) else { return }
        let operation: TerminalGroupSavedLayoutSaveOperation =
            snapshot.savedLayoutID.map { .save(existingID: $0) } ?? .firstSave
        saveTerminalGroup(snapshot, groupID: groupID, name: snapshot.name, operation: operation)
    }

    func saveTerminalGroupAs(
        _ groupID: TerminalGroupID, name rawName: String,
        operation: TerminalGroupSavedLayoutSaveOperation = .saveAs,
        pendingPresentationEpoch: UInt64? = nil
    ) {
        guard let snapshot = terminal.terminalGroup(groupID),
            let name = TerminalGroupName(rawName)
        else {
            presentTerminalGroupError("Enter a valid Terminal Group name.")
            finishPendingTerminalGroupSaveSubmission(
                groupID: groupID, presentationEpoch: pendingPresentationEpoch,
                succeeded: false, errorMessage: "Enter a valid Terminal Group name.")
            return
        }
        do {
            let namedSnapshot = try TerminalGroupSnapshot(
                id: snapshot.id, name: name, root: snapshot.root,
                focusedPaneID: snapshot.focusedPaneID, savedLayoutID: snapshot.savedLayoutID,
                panes: snapshot.panes, retainedPaneCount: retainedTerminalPaneCount)
            saveTerminalGroup(
                namedSnapshot, groupID: groupID, name: name, operation: operation,
                pendingPresentationEpoch: pendingPresentationEpoch)
        } catch {
            let message = error.localizedDescription
            presentTerminalGroupError(message)
            finishPendingTerminalGroupSaveSubmission(
                groupID: groupID, presentationEpoch: pendingPresentationEpoch,
                succeeded: false, errorMessage: message)
        }
    }

    private func saveTerminalGroup(
        _ snapshot: TerminalGroupSnapshot,
        groupID: TerminalGroupID,
        name: TerminalGroupName,
        operation: TerminalGroupSavedLayoutSaveOperation,
        presentNameRequestOnConflict: Bool = false,
        pendingPresentationEpoch: UInt64? = nil
    ) {
        guard let rootURL, terminalGroupMutationTask == nil else {
            let message =
                rootURL == nil
                ? "Open a workspace before saving a Terminal Group."
                : "A Terminal Group save is already in progress."
            finishPendingTerminalGroupSaveSubmission(
                groupID: groupID, presentationEpoch: pendingPresentationEpoch,
                succeeded: false, errorMessage: message)
            return
        }
        let key = TerminalGroupWorkspaceKey(standardizedRoot: rootURL)
        let generation = terminalGroupWorkspaceGeneration
        terminalGroupMutationEpoch &+= 1
        let epoch = terminalGroupMutationEpoch
        terminalGroupMutationTask = Task { [weak self] in
            defer { self?.terminalGroupSaveTaskFinishedForTesting?() }
            do {
                let record = try TerminalGroupRestorationCodec().savedRecord(
                    from: snapshot,
                    savedLayoutID: snapshot.savedLayoutID)
                let request = try TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: key, operation: operation, group: record)
                guard let self else { return }
                let store = await self.resolvedTerminalGroupSavedLayoutStore()
                let result = try await store.saveSavedLayout(request)
                guard !Task.isCancelled,
                    self.terminalGroupWorkspaceGeneration == generation,
                    self.terminalGroupMutationEpoch == epoch
                else { return }
                guard self.terminal.terminalGroup(groupID) != nil else {
                    self.terminalGroupMutationTask = nil
                    return
                }
                _ = try self.terminal.perform(
                    .commitSavedLayout(
                        groupID: groupID, savedLayoutID: result.savedLayoutID, name: name))
                self.terminalGroupMutationTask = nil
                self.finishPendingTerminalGroupSaveSubmission(
                    groupID: groupID, presentationEpoch: pendingPresentationEpoch)
                self.loadTerminalGroupLibrary(key: key, generation: generation)
                self.persistWorkspaceState()
            } catch {
                guard let self, !Task.isCancelled,
                    self.terminalGroupWorkspaceGeneration == generation,
                    self.terminalGroupMutationEpoch == epoch
                else { return }
                self.terminalGroupMutationTask = nil
                self.finishPendingTerminalGroupSaveSubmission(
                    groupID: groupID, presentationEpoch: pendingPresentationEpoch,
                    succeeded: false, errorMessage: error.localizedDescription)
                if presentNameRequestOnConflict,
                    let persistence = error as? TerminalGroupPersistenceError,
                    persistence == .nameConflict,
                    self.terminal.terminalGroup(groupID) != nil
                {
                    self.terminalGroupSavePresentationEpoch &+= 1
                    self.pendingTerminalGroupSaveRequest = TerminalGroupSaveRequest(
                        id: groupID, kind: .firstSave, proposedName: snapshot.name.rawValue)
                    return
                }
                if pendingPresentationEpoch == nil {
                    self.terminalGroupStoreError = String(
                        decoding: error.localizedDescription.utf8.prefix(512), as: UTF8.self)
                }
            }
        }
    }

    var rootURL: URL? {
        guard case .local(let reference) = descriptor?.location else { return nil }
        return URL(fileURLWithPath: reference.path, isDirectory: true)
    }

    var selectedDocument: EditorDocument? {
        openDocuments.first { $0.id == selectedDocumentID }
    }

    /// Whether the editor layout has any tab at all — file or terminal.
    /// `EditorCanvasView` uses this (rather than `openDocuments.isEmpty`) to
    /// decide between the "workspace is open, nothing to show yet" welcome
    /// view and the real editor tree, since a terminal-only layout has no
    /// open documents but still has a tab to render (issue #4).
    var hasAnyEditorTabs: Bool {
        editorLayout.groupIDs.contains { editorLayout.group(id: $0)?.tabs.isEmpty == false }
    }

    /// Session ids currently shown as a `.terminal` tab anywhere in the
    /// editor layout (any group, any split pane).
    var presentedTerminalSessionIDs: Set<UUID> {
        var ids = Set<UUID>()
        for groupID in editorLayout.groupIDs {
            guard let group = editorLayout.group(id: groupID) else { continue }
            for tab in group.tabs {
                switch tab.resource {
                case .terminal(let sessionID): ids.insert(sessionID)
                case .terminalGroup(let terminalGroupID):
                    for pane in terminal.terminalGroup(terminalGroupID)?.panes ?? [] {
                        if let sessionID = pane.sessionID { ids.insert(sessionID) }
                    }
                case .file, .restorable: break
                }
            }
        }
        return ids
    }

    /// Sessions alive in `terminal.sessions` but not currently presented as
    /// a tab (hidden via ⌃`/`hideTerminalTab(_:)`), most-recently-parked
    /// first. Deliberately not dual-bookkept — derived from the layout each
    /// call, so it can never drift from what is actually on screen. Do not
    /// call from a `View.body` hot path; a caller that needs this every
    /// frame should snapshot it once.
    var parkedTerminalSessions: [WorkspaceTerminalController] {
        let presented = presentedTerminalSessionIDs
        return terminal.sessions
            .filter {
                terminal.terminalGroupAndPane(containing: $0.id) == nil
                    && !presented.contains($0.id)
            }
            .sorted { ($0.parkSequence, $0.index) > ($1.parkSequence, $1.index) }
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
        // Only newly-hibernated documents are worth a timeline entry. This
        // runs on every selection change, so filing an event unconditionally
        // would bury real activity under a row per tab switch.
        var newlyHibernated = 0
        for document in openDocuments {
            if hibernating.contains(document.id) {
                if document.loadState != .hibernated { newlyHibernated += 1 }
                document.markHibernated()
            } else {
                document.markLoaded()
            }
        }
        if newlyHibernated > 0 {
            MemoryTimeline.shared.note(
                .documentsHibernated,
                detail: newlyHibernated == 1 ? "1 tab" : "\(newlyHibernated) tabs",
                source: memoryTimelineSource)
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

        // Old terminal/run callbacks still belong to the old descriptor and
        // security scope. Drain them before replacing any workspace state.
        teardownTerminalGroups()
        didTeardownTerminalGroups = false
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
        languageIntelligence.workspaceDidClose()
        RecentWorkspacesStore().record(url: url, displayName: name)
        Task { await refreshWorkspace() }
        reloadConductorRuns(for: url)
        startFileWatcher()
        languageIntelligence.workspaceDidOpen(root: url)
        beginTerminalGroupLibrary(for: url)
        persistWorkspaceState()

        previousSecurityScopedURL?.stopAccessingSecurityScopedResource()
    }

    /// Loads persisted `.rafu/runs/` manifests for `url`, independent of
    /// whether the `.runs` navigator panel is mounted (`ConductorRunsPanelView`
    /// separately reloads on `.task(id:)` for its own live-attachment case —
    /// this is a second, idempotent, read-only caller of the same
    /// evidence-only path, not a replacement for it). Called from both
    /// `openLocalWorkspace(at:)` and `restoreLastWorkspaceIfAvailable()`, the
    /// two funnels that give a window a new workspace root.
    private func reloadConductorRuns(for url: URL) {
        Task { await conductorRunController.attachAndReload(workspaceRoot: url) }
        conductorWorkflowController.attach(workspaceRoot: url)
        conductorConcurrentRuns.attach(workspaceRoot: url)
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

    /// Moves the caret to the start of `line` (1-based) in the active editor
    /// and scrolls it into view — the ⌃G command palette's go-to-line entry
    /// point (issue #14). Reuses `DocumentFindState.select(_:)`'s
    /// scroll+select+focus contract, the same path `openWorkspaceSymbol`
    /// uses. A no-op when there is no selected document or its editor isn't
    /// mounted (no live text snapshot).
    func goToLine(_ line: Int) {
        guard let document = selectedDocument, let snapshotProvider = document.textSnapshotProvider
        else { return }
        let offset = LineColumnIndex.utf16Offset(line: line, column: 1, in: snapshotProvider())
        findState(for: document).select(NSRange(location: offset, length: 0))
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

    /// Hover for the NEW side of an open, WORKING-TREE-scoped diff — the
    /// diff canvas's only supported hover surface
    /// (`docs/plans/phases/diff-syntax-highlighting-and-hover.md`). The old
    /// side and any history/commit-scoped diff NEVER get hover: that text
    /// may not exist on disk or may not match what the language server has
    /// synced, so any answer about it would be a guess — a deliberate
    /// product decision, not a deferral. Sibling to `hoverInfo(at:
    /// utf16Offset:)` rather than a loosened guard on it: the diff canvas is
    /// never `selectedDocument`, so that function's document-identity guard
    /// can stay exactly as strict as it is today.
    ///
    /// Reads the CURRENT text: the matching open document's live snapshot
    /// when it is open and not dirty (an unsaved edit shifts line numbers,
    /// so hover suppresses rather than lying — same rule inline blame
    /// follows), otherwise the on-disk file via `fileService.readText`.
    /// `nil` when: there is no workspace root, the open diff doesn't match
    /// `path`, the diff's scope isn't `.workingTree`, the matching open
    /// document is dirty, the text can't be read, `DiffHoverPositionMapper`
    /// can't place `(line, utf16Column)` in that text (the file changed
    /// since the diff was captured), or every navigation tier declines —
    /// the same LSP-only contract as `hoverInfo(at:utf16Offset:)`, reused
    /// unmodified via the same `navigationLadder`.
    ///
    /// LSP document-sync caveat: if `path` isn't open in the editor, the
    /// language server may have no synced document for it
    /// (`documentDidOpen` only fires on open, see `registerDocument`). This
    /// deliberately does NOT open a hidden/transient document to force a
    /// sync — a closed file's hover simply doesn't appear until the file is
    /// opened once; that limitation is documented, not worked around, in
    /// this phase.
    func diffHoverInfo(path: String, line: Int, utf16Column: Int) async -> EditorHoverInfo? {
        guard let rootURL,
            let gitOpenDiff, gitOpenDiff.diff.path == path,
            gitOpenDiff.scope == .workingTree,
            let ladder = navigationLadder
        else { return nil }

        let documentURL = rootURL.appending(path: path)
        let openDocument = openDocuments.first { $0.url == documentURL }
        if let openDocument, openDocument.isDirty { return nil }

        let text: String
        if let snapshot = openDocument?.textSnapshotProvider?() {
            text = snapshot
        } else if let onDisk = try? await fileService.readText(at: documentURL) {
            text = onDisk
        } else {
            return nil
        }

        guard
            let offset = DiffHoverPositionMapper.utf16Offset(
                line: line, utf16Column: utf16Column, in: text)
        else { return nil }

        let symbolName = IdentifierUnderCaret.word(in: text, at: offset)?.word
        let request = NavigationRequest(
            documentURL: documentURL,
            position: offset,
            languageID: resolveLanguageID(for: documentURL),
            kind: .hover,
            symbolName: symbolName
        )
        let answer = try? await ladder.resolve(request)
        guard let hoverText = answer?.candidates.first?.previewLine, !hoverText.isEmpty else {
            return nil
        }
        let parsed = HoverMarkdownParser.parse(hoverText, isMarkdown: true)
        return EditorHoverInfo(
            text: hoverText,
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

    /// FSEvents path: re-lists affected directories that the sidebar has
    /// already materialized. The refresh scope also includes materialized
    /// direct children: FSEvents can report an expanded directory while the
    /// classifier records its parent, as when `.rafu/runs` is created. Paths
    /// never opened in the sidebar remain unloaded.
    private func refreshChangedDirectories(_ changedDirectoryRelativePaths: Set<String>) async {
        guard let rootURL else { return }
        let materializedChanged = WorkspaceFileTreeRefreshScope.materializedDirectories(
            affectedBy: changedDirectoryRelativePaths,
            among: Set(loadedChildren.keys)
        )
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
            if case .ready(let count, _) = fileIndexState {
                MemoryTimeline.shared.note(
                    .fileIndexBuilt, detail: "\(count) files",
                    source: memoryTimelineSource)
            }
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
        // The working-tree peek diff is cached by (path, revision), which does
        // not change when the index changes (stage/unstage/commit here, in the
        // Source Control panel, or in a terminal). refreshGit runs after every
        // such mutation, so invalidate the cache here to keep a reopened hunk
        // peek coherent with the actual index.
        workingTreeDiffCache = nil
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
            MemoryTimeline.shared.note(
                .gitRefreshed, detail: "\(snapshot.changes.count) changes",
                source: memoryTimelineSource)
        } catch {
            reportGitError(error)
        }
    }

    /// Appends the next page of commit history to `gitHistoryPage`,
    /// preserving `hasMore`'s existing `commits.count == requestedCount`
    /// formula by carrying `requestedCount` forward across the merge —
    /// `hasMore` is true after this exactly when the freshly fetched page
    /// was itself full (100 commits), which is the honest signal that more
    /// history may exist. `refreshGit()`'s initial single-page load is
    /// unchanged; this is the explicit "Load More" continuation only —
    /// never automatic, never a background poll (GX3, ADR 0013).
    func loadMoreHistory() async {
        guard let rootURL, let currentPage = gitHistoryPage, currentPage.hasMore, !isGitBusy else {
            return
        }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            let nextPage = try await gitService.history(
                at: rootURL, limit: 100, offset: currentPage.commits.count)
            guard self.rootURL == rootURL,
                let existing = gitHistoryPage,
                existing.commits.count == currentPage.commits.count,
                existing.offset == currentPage.offset
            else { return }
            gitHistoryPage = GitHistoryPage(
                commits: existing.commits + nextPage.commits,
                offset: existing.offset,
                requestedCount: existing.commits.count + nextPage.requestedCount
            )
        } catch is CancellationError {
            return
        } catch {
            guard self.rootURL == rootURL else { return }
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
        registerDocument(EditorDocument(url: url))
    }

    /// Which window a `MemoryTimeline` event came from. Every Rafu window
    /// shares one process and therefore one timeline, so an event with no
    /// source is indistinguishable from one another window just filed.
    /// Empty before a workspace is opened — a window with nothing in it has
    /// no name worth showing.
    var memoryTimelineSource: String { descriptor?.displayName ?? "" }

    private func registerDocument(_ document: EditorDocument) -> EditorDocument {
        openDocuments.append(document)
        documentFindStates[document.id] = DocumentFindState()
        languageIntelligence.documentDidOpen(document)
        MemoryTimeline.shared.note(
            .documentOpened, detail: document.url.lastPathComponent,
            source: memoryTimelineSource)
        return document
    }

    /// Monotonic counter for untitled tabs' display names ("Untitled",
    /// "Untitled 2", …); never reused, so closing one and opening another
    /// never collides with a still-open tab.
    @ObservationIgnored
    private var untitledDocumentCounter = 0

    /// Opens a new blank, unsaved editor tab with no backing file — the ⌘N
    /// entry point (issue #6). Selects the new tab immediately, exactly like
    /// `open(_:)` does for a file. `⌘S` on it routes through
    /// `saveUntitledDocument(_:)` to a save panel; see `EditorDocument.isUntitled`.
    func newUntitledDocument() {
        untitledDocumentCounter += 1
        let document = registerDocument(EditorDocument(untitledNumber: untitledDocumentCounter))
        select(document)
    }

    /// ⌘S on an untitled tab (issue #6): prompts for a destination with
    /// `NSSavePanel`, then gives the document that URL and performs the
    /// first real write through its existing `saveAction` (so the write
    /// path, dirty-flag clearing, and Git refresh stay identical to a normal
    /// save).
    func saveUntitledDocument(_ document: EditorDocument) {
        presentSavePanel(for: document) { [weak self] in
            self?.persistWorkspaceState()
        }
    }

    /// "Save and Close" (`EditorCanvasView`'s unsaved-changes sheet) on a
    /// dirty untitled tab: the same save-panel flow as
    /// `saveUntitledDocument(_:)`, but the tab only closes once the panel
    /// actually returns a destination — a cancelled panel leaves the tab
    /// open and still dirty instead of silently discarding it.
    private func saveUntitledDocumentThenClose(_ document: EditorDocument) {
        presentSavePanel(for: document) { [weak self] in
            self?.close(document)
        }
    }

    /// Shared `NSSavePanel` flow backing both untitled-save paths above:
    /// retargets the tab/document's resource to the chosen URL, then
    /// performs the first real write through `saveAction`. A no-op (no
    /// panel shown) for a document that isn't untitled or has no mounted
    /// editor; `onSaved` never runs when the panel is cancelled.
    private func presentSavePanel(for document: EditorDocument, onSaved: @escaping () -> Void) {
        guard document.isUntitled, document.saveAction != nil else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = document.displayName
        if let rootURL {
            panel.directoryURL = rootURL
        }
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let previousURL = document.url
            document.assignSavedURL(url)
            if let tab = editorLayout.tab(matching: .file(previousURL)) {
                editorLayout.updateResource(for: tab.id, to: .file(url))
            }
            if selectedDocumentID == document.id {
                selectedTreePath = url.path
            }
            document.saveAction?()
            onSaved()
        }
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
        pendingCloseDocument = nil
        if document.isUntitled {
            saveUntitledDocumentThenClose(document)
            return
        }
        document.saveAction?()
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
        MemoryTimeline.shared.note(
            .documentClosed, detail: document.url.lastPathComponent,
            source: memoryTimelineSource)
        synchronizeSelectionFromLayout(
            fallback: openDocuments.indices.contains(index)
                ? openDocuments[index] : openDocuments.last
        )
        updateHibernationStates()
        persistWorkspaceState()
    }

    /// ⌘S. An untitled document (issue #6) routes to `saveUntitledDocument(_:)`'s
    /// save panel; a normal file-backed document keeps writing straight to
    /// its existing URL.
    func saveSelectedDocument() {
        guard let selectedDocument else { return }
        if selectedDocument.isUntitled {
            saveUntitledDocument(selectedDocument)
            return
        }
        selectedDocument.saveAction?()
    }

    /// Cmd+W's first-priority target: the selected tab in the FOCUSED
    /// editor group, if any. Mirrors the tab strip's own close semantics per
    /// resource kind — a file tab keeps the dirty-save confirmation
    /// (`requestClose`), a terminal tab terminates its shell via
    /// `closeTerminalTab` rather than parking it (ADR 0014 — a generic
    /// close defaults to close, never `hideTerminalTab`), and a
    /// `.restorable` placeholder tab closes outright since it backs no
    /// live process or dirty document (`EditorTabResource.isRestorable`).
    /// Returns `false` when the focused group has no selected tab, so
    /// `requestCloseActiveTab()` can fall through to its git-diff and
    /// empty-window branches.
    private func closeFocusedTabIfPresent() -> Bool {
        guard let group = editorLayout.group(id: editorLayout.focusedGroupID),
            let selectedTabID = group.selectedTabID,
            let tab = group.tabs.first(where: { $0.id == selectedTabID })
        else { return false }

        switch tab.resource {
        case .file:
            guard let document = document(for: tab) else { return false }
            requestClose(document)
        case .terminal:
            closeTerminalTab(tab.id)
        case .terminalGroup(let terminalGroupID):
            requestTerminalGroupClose(terminalGroupID)
        case .restorable:
            _ = editorLayout.closeTab(tab.id)
            synchronizeSelectionFromLayout()
            persistWorkspaceState()
        }
        return true
    }

    /// What `requestCloseActiveTab()` does once a window is confirmed
    /// truly empty (no tab, no Git diff). Pulled out as a pure function of
    /// its inputs — rather than inlined against `NSApp`/`WorkspaceWindowRegistry`
    /// — so the decision is unit-testable without driving real AppKit
    /// window-closing machinery.
    enum EmptyWindowCloseAction: Equatable {
        /// Other workspace windows remain open: close only this one.
        case closeWindow
        /// This is the last window and the user opted out of the
        /// confirmation prompt.
        case quitWithoutConfirmation
        /// This is the last window: show the existing quit-confirmation UX.
        case presentQuitConfirmation
    }

    static func resolveEmptyWindowCloseAction(
        hasOtherWorkspaceWindows: Bool,
        quitWithoutEmptyWindowConfirmation: Bool
    ) -> EmptyWindowCloseAction {
        if hasOtherWorkspaceWindows { return .closeWindow }
        return quitWithoutEmptyWindowConfirmation
            ? .quitWithoutConfirmation : .presentQuitConfirmation
    }

    /// Cmd+W. Resolves in order: the focused group's selected tab (file,
    /// terminal, or restorable placeholder); else an editor-hosted Git
    /// diff; else — a truly empty window — closes only THIS window when
    /// other workspace windows remain open, and otherwise preserves the
    /// existing last-window quit-confirmation UX. Closing only this
    /// window (rather than `NSApp.terminate`) is required because an empty
    /// focused window used to quit every open workspace window.
    func requestCloseActiveTab() {
        guard !isTerminalGroupModalInputBlocked else { return }
        if closeFocusedTabIfPresent() {
            return
        }
        if gitOpenDiff != nil {
            closeGitDiff()
            return
        }
        let hasOtherWorkspaceWindows = WorkspaceWindowRegistry.shared.liveWorkspaceWindowCount() > 1
        switch Self.resolveEmptyWindowCloseAction(
            hasOtherWorkspaceWindows: hasOtherWorkspaceWindows,
            quitWithoutEmptyWindowConfirmation: UserDefaults.standard.bool(
                forKey: "quitWithoutEmptyWindowConfirmation")
        ) {
        case .closeWindow:
            WorkspaceWindowRegistry.shared.closeWindow(for: self)
        case .quitWithoutConfirmation:
            NSApp.terminate(nil)
        case .presentQuitConfirmation:
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
        let state = findState(for: selectedDocument)
        state.activate()
        state.requestQueryFocus()
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

    func moveLineUp() {
        selectedDocument?.moveLineUpAction?()
    }

    func moveLineDown() {
        selectedDocument?.moveLineDownAction?()
    }

    func duplicateLineUp() {
        selectedDocument?.duplicateLineUpAction?()
    }

    func duplicateLineDown() {
        selectedDocument?.duplicateLineDownAction?()
    }

    func deleteLine() {
        selectedDocument?.deleteLineAction?()
    }

    /// Every open editor tab plus every parked terminal session, in stable
    /// visual order (groups, then tabs) followed by parked-terminal MRU.
    /// Presented terminal sessions are represented by their session id and
    /// therefore appear exactly once even though they also have an editor tab.
    var editorTabSwitcherCandidates: [EditorTabSwitcherCandidate] {
        var candidates: [EditorTabSwitcherCandidate] = []
        let terminalSessionIDs = Set(terminal.sessions.map(\.id))

        for groupID in editorLayout.groupIDs {
            guard let group = editorLayout.group(id: groupID) else { continue }
            for tab in group.tabs {
                let destination: EditorTabSwitcherDestination
                switch tab.resource {
                case .terminal(let sessionID):
                    guard terminalSessionIDs.contains(sessionID) else { continue }
                    destination = .terminal(sessionID: sessionID)
                case .terminalGroup(let terminalGroupID):
                    guard terminal.terminalGroup(terminalGroupID) != nil else { continue }
                    destination = .terminalGroup(groupID: terminalGroupID)
                case .file, .restorable:
                    destination = .editorTab(tabID: tab.id, groupID: groupID)
                }
                candidates.append(EditorTabSwitcherCandidate(destination: destination))
            }
        }

        candidates.append(
            contentsOf: parkedTerminalGroupIDs.map {
                EditorTabSwitcherCandidate(destination: .terminalGroup(groupID: $0))
            })
        candidates.append(
            contentsOf: parkedTerminalSessions.map {
                EditorTabSwitcherCandidate(destination: .terminal(sessionID: $0.id))
            })
        return candidates
    }

    var canCycleEditorTabs: Bool {
        editorTabSwitcherCandidates.count > 1
    }

    /// Starts Ctrl-Tab from the focused tab, or advances an already-visible
    /// switcher from its highlighted destination. This updates only the
    /// overlay's ephemeral selection; `commitEditorTabSwitcher()` performs
    /// the actual editor/terminal selection once.
    func cycleEditorTabSwitcher(_ direction: EditorTabSwitcherDirection) {
        let candidates = editorTabSwitcherCandidates
        let current =
            editorTabSwitcherState?.selectedCandidate.destination
            ?? focusedTabSwitcherDestination
        editorTabSwitcherState = EditorTabSwitcherState(
            candidates: candidates,
            current: current,
            direction: direction
        )
    }

    func moveEditorTabSwitcherSelection(_ direction: EditorTabSwitcherDirection) {
        guard var state = editorTabSwitcherState else { return }
        state.move(direction)
        editorTabSwitcherState = state
    }

    func commitEditorTabSwitcher() {
        guard let destination = editorTabSwitcherState?.selectedCandidate.destination else {
            return
        }
        editorTabSwitcherState = nil
        activateEditorTabSwitcherDestination(destination)
    }

    func commitEditorTabSwitcher(to destination: EditorTabSwitcherDestination) {
        guard var state = editorTabSwitcherState else { return }
        state.select(destination)
        editorTabSwitcherState = state
        commitEditorTabSwitcher()
    }

    func cancelEditorTabSwitcher() {
        editorTabSwitcherState = nil
    }

    private var focusedTabSwitcherDestination: EditorTabSwitcherDestination? {
        let groupID = editorLayout.focusedGroupID
        guard let group = editorLayout.group(id: groupID),
            let selectedTabID = group.selectedTabID,
            let tab = group.tabs.first(where: { $0.id == selectedTabID })
        else { return nil }
        if case .terminal(let sessionID) = tab.resource {
            return .terminal(sessionID: sessionID)
        }
        if case .terminalGroup(let terminalGroupID) = tab.resource {
            return .terminalGroup(groupID: terminalGroupID)
        }
        return .editorTab(tabID: tab.id, groupID: groupID)
    }

    private func activateEditorTabSwitcherDestination(
        _ destination: EditorTabSwitcherDestination
    ) {
        switch destination {
        case .editorTab(let tabID, let groupID):
            selectEditorTab(tabID, in: groupID)
        case .terminal(let sessionID):
            revealTerminalSession(sessionID)
        case .terminalGroup(let groupID):
            revealTerminalGroup(groupID)
        }
    }

    func selectEditorTab(_ tabID: EditorTabID, in groupID: EditorGroupID) {
        guard let tab = editorLayout.group(id: groupID)?.tabs.first(where: { $0.id == tabID })
        else { return }
        editorLayout.select(tabID, in: groupID)
        switch tab.resource {
        case .file:
            guard let document = document(for: tab) else { return }
            selectedDocumentID = document.id
            selectedTreePath = document.url.path
            recordAccess(document)
            updateHibernationStates()
        case .terminal(let sessionID):
            selectedDocumentID = nil
            selectedTreePath = nil
            terminal.selectedID = sessionID
            // Bell-clear hook 1/3 (terminal-manager.md T-E) — see
            // `synchronizeSelectionFromLayout` and `revealTerminalSession`
            // for the other two.
            terminal.sessions.first(where: { $0.id == sessionID })?.clearAttention()
        case .terminalGroup(let terminalGroupID):
            selectedDocumentID = nil
            selectedTreePath = nil
            if let paneID = terminal.terminalGroup(terminalGroupID)?.focusedPaneID {
                terminal.selectedID = terminal.terminalController(for: paneID)?.id
                terminal.terminalController(for: paneID)?.clearAttention()
                terminalGroupFocusRequest &+= 1
            }
        case .restorable:
            selectedDocumentID = nil
            selectedTreePath = nil
        }
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

    /// The tab-strip counterpart to `moveEditorTab`/`splitEditorTab`: a tab
    /// dropped on a tab strip either reorders in place (same group) or moves
    /// into `groupID` at the hovered slot (a different group's strip),
    /// instead of always appending to the end or splitting. Unknown tab IDs
    /// are ignored, mirroring `handleEditorTabDrop`; a same-group drop that
    /// resolves to no actual reorder (dropping a tab back where it already
    /// is) skips every side effect so it never flips focus or churns
    /// persistence.
    func reorderOrMoveEditorTab(
        _ tabID: EditorTabID,
        to groupID: EditorGroupID,
        atInsertionIndex index: Int
    ) {
        guard let sourceGroupID = editorLayout.group(containing: tabID)?.id else { return }
        let didChange =
            sourceGroupID == groupID
            ? editorLayout.reorderTab(tabID, in: groupID, toInsertionIndex: index)
            : editorLayout.moveTab(tabID, to: groupID, at: index)
        guard didChange else { return }
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

    /// A Finder drop of multiple files onto a group: opens every path via
    /// `handleEditorFileDrop`, applying the hovered split `edge` only to the
    /// FIRST file so the drop doesn't split once per file. Subsequent files
    /// open (or reuse their tab) in the resulting group with a `nil` edge,
    /// mirroring one "open these files" action. Directory rejection and
    /// already-open-tab dedupe are unchanged — each path still goes through
    /// `handleEditorFileDrop`'s own guards.
    func handleEditorFileDrops(paths: [String], on groupID: EditorGroupID, edge: EditorSplitEdge?) {
        guard let firstPath = paths.first else { return }
        handleEditorFileDrop(path: firstPath, on: groupID, edge: edge)
        guard paths.count > 1 else { return }
        // The first drop may have split off a new group (a non-nil edge); the
        // remaining files land in whichever group now holds the first file so
        // they end up together instead of splitting again.
        let targetGroupID =
            editorLayout.tab(matching: .file(URL(fileURLWithPath: firstPath)))
            .flatMap { editorLayout.group(containing: $0.id)?.id } ?? groupID
        for path in paths.dropFirst() {
            handleEditorFileDrop(path: path, on: targetGroupID, edge: nil)
        }
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

    /// The folder new items and pastes target: the selected tree folder, the
    /// selected file's parent, or the workspace root.
    var selectedFolderURL: URL? {
        guard let rootURL else { return nil }
        guard let selectedTreePath else { return rootURL }
        let rootPath = rootURL.standardizedFileURL.path
        let selected = URL(filePath: selectedTreePath).standardizedFileURL
        guard selected.path == rootPath || selected.path.hasPrefix(rootPath + "/") else {
            return rootURL
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: selected.path, isDirectory: &isDirectory)
        else { return rootURL }
        return isDirectory.boolValue ? selected : selected.deletingLastPathComponent()
    }

    func requestFileCreation(in parentURL: URL? = nil, isDirectory: Bool) {
        // No explicit parent (the sidebar-header buttons) → create inside the
        // selected folder / the selected file's folder, not always the root.
        guard let directory = parentURL ?? selectedFolderURL ?? rootURL else { return }
        pendingFileName = ""
        pendingFileCreation = FileCreationRequest(parentURL: directory, isDirectory: isDirectory)
    }

    /// Tree drop handler shared by the root list and per-folder rows: items
    /// already inside the workspace MOVE; items from outside (Finder) COPY in.
    func handleTreeDrop(_ urls: [URL], into directory: URL) async {
        guard let rootURL else { return }
        let rootPath = rootURL.standardizedFileURL.path
        var changed = false
        for url in urls {
            let sourcePath = url.standardizedFileURL.path
            do {
                if sourcePath == rootPath { continue }
                if sourcePath.hasPrefix(rootPath + "/") {
                    let destination = try await fileService.move(url, into: directory)
                    rebindOpenDocuments(from: url, to: destination)
                } else {
                    _ = try await fileService.importItem(at: url, into: directory)
                }
                changed = true
            } catch {
                reportOpenFolderError(error)
            }
        }
        if changed { await refreshWorkspace() }
    }

    /// ⌘V / context-menu Paste into the selected folder. Handles copied files
    /// (Finder or Rafu's own Copy File) and clipboard images (screenshots
    /// captured with ⌃⇧⌘4), written as a timestamped PNG.
    func pasteIntoSelectedFolder(target: URL? = nil) {
        guard let directory = target ?? selectedFolderURL else { return }
        let pasteboard = NSPasteboard.general
        Task {
            do {
                if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
                    !urls.isEmpty
                {
                    for url in urls where url.isFileURL {
                        _ = try await fileService.importItem(at: url, into: directory)
                    }
                } else if let imageData = Self.pasteboardPNGData(from: pasteboard) {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
                    let name = "Screenshot \(formatter.string(from: Date())).png"
                    _ = try await fileService.writeData(imageData, named: name, into: directory)
                } else {
                    return
                }
                await refreshWorkspace()
            } catch {
                reportOpenFolderError(error)
            }
        }
    }

    /// PNG bytes from the general pasteboard, converting TIFF screenshots.
    private static func pasteboardPNGData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff),
            let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Points open documents (and their tabs) at a moved file or folder so a
    /// tree drag never orphans an open editor.
    private func rebindOpenDocuments(from oldURL: URL, to newURL: URL) {
        let oldPath = oldURL.standardizedFileURL.path
        for document in openDocuments {
            let documentPath = document.url.standardizedFileURL.path
            if documentPath == oldPath {
                if let tab = editorLayout.tab(matching: .file(document.url)) {
                    editorLayout.updateResource(for: tab.id, to: .file(newURL))
                }
                document.url = newURL
            } else if documentPath.hasPrefix(oldPath + "/") {
                let suffix = documentPath.dropFirst(oldPath.count)
                let movedURL = URL(fileURLWithPath: newURL.path + suffix)
                if let tab = editorLayout.tab(matching: .file(document.url)) {
                    editorLayout.updateResource(for: tab.id, to: .file(movedURL))
                }
                document.url = movedURL
            }
        }
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
            MemoryTimeline.shared.note(
                .diffOpened, detail: (change.path as NSString).lastPathComponent,
                source: memoryTimelineSource)
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
            MemoryTimeline.shared.note(
                .diffOpened, detail: (change.path as NSString).lastPathComponent,
                source: memoryTimelineSource)
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
        if gitOpenDiff != nil {
            MemoryTimeline.shared.note(.diffClosed, source: memoryTimelineSource)
        }
        gitOpenDiff = nil
        // A run diff opened from the run-detail canvas (C5) returns to the
        // timeline, not a document fallback — the canvas is still hosting.
        if wasSelected, conductorRunCanvasID == nil, let fallback = openDocuments.last {
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

    // MARK: - Worktrees

    /// The absolute standardized path of the worktree Rafu currently has open,
    /// used to mark the "current" row. Prefers the git repository root (the
    /// worktree's own top), falling back to the opened folder.
    var currentWorktreePath: String? {
        (gitSnapshot?.repositoryRoot ?? rootURL)?.standardizedFileURL.path
    }

    /// Loads `git worktree list` for the Source Control worktrees section.
    /// Called on explicit section expand and after worktree mutations — never
    /// polled, and never watches sibling worktrees.
    func loadWorktrees() async {
        guard let rootURL, !isGitWorktreesLoading else { return }
        isGitWorktreesLoading = true
        defer { isGitWorktreesLoading = false }
        do {
            let worktrees = try await gitService.worktrees(at: rootURL)
            guard self.rootURL == rootURL else { return }
            gitWorktrees = worktrees
        } catch is CancellationError {
            return
        } catch {
            guard self.rootURL == rootURL else { return }
            reportGitError(error)
        }
    }

    /// Opens a worktree as a new workspace window, reusing the same in-app
    /// folder-open path the CLI uses (enqueue → open a fresh window that
    /// consumes the request and skips last-workspace restoration).
    func openWorktreeInNewWindow(_ worktree: GitWorktree) {
        let url = URL(filePath: worktree.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            reportGitError(GitServiceError.invalidGitPath)
            return
        }
        ExternalOpenRequests.shared.enqueue([url])
        _ = WorkspaceWindowRegistry.shared.openWorkspaceWindow()
    }

    /// Adds a worktree, then refreshes the list. `createBranch` chooses
    /// `git worktree add -b <branch> <path>` vs checking out an existing
    /// branch at `<path>`.
    func addWorktree(at path: URL, branch: String?, createBranch: Bool) async {
        guard let rootURL, !isGitBusy else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            try await gitService.addWorktree(
                path: path, branch: branch, createBranch: createBranch, at: rootURL)
            guard self.rootURL == rootURL else { return }
            await loadWorktrees()
        } catch is CancellationError {
            return
        } catch {
            guard self.rootURL == rootURL else { return }
            reportGitError(error)
        }
    }

    /// Removes a worktree (never `--force`; git refuses dirty/locked and the
    /// real error surfaces), then refreshes the list.
    func removeWorktree(_ worktree: GitWorktree) async {
        guard let rootURL, !isGitBusy, !worktree.isMain else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            try await gitService.removeWorktree(path: worktree.path, at: rootURL)
            guard self.rootURL == rootURL else { return }
            await loadWorktrees()
        } catch is CancellationError {
            return
        } catch {
            guard self.rootURL == rootURL else { return }
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

    /// Resolves `document`'s workspace URL to a Git-repository-relative
    /// path, exactly like the resolution `gutterLineChanges(for:)` and
    /// `openBlameForSelectedFile()` perform inline. `nil` when there is no
    /// repository or the file lives outside it — callers skip without
    /// spawning any process. Shared by the GX1 inline-blame and GX2
    /// hunk-peek/blame-hover lookups so both stay consistent with the
    /// existing gutter/blame resolution.
    private func gitRepositoryRelativePath(for document: EditorDocument) -> String? {
        guard let gitSnapshot, let repositoryRoot = gitSnapshot.repositoryRoot ?? rootURL else {
            return nil
        }
        let rootPath = repositoryRoot.standardizedFileURL.path
        let filePath = document.url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return nil }
        let relativePath = String(filePath.dropFirst(rootPath.count + 1))
        return relativePath.isEmpty ? nil : relativePath
    }

    // MARK: - GX1 inline blame

    /// Toggles the per-window inline-blame ghost annotation (View menu /
    /// command palette "Toggle Inline Blame"). Not persisted (ADR 0013, GD2).
    func toggleInlineBlame() {
        isInlineBlameEnabled.toggle()
        if !isInlineBlameEnabled { inlineBlameStore.invalidate() }
    }

    /// Computes (or returns the cached) `GitBlame` for `document`'s GX1
    /// inline-blame annotation. Returns `nil` — no process spawned, no cache
    /// touched — when inline blame is off, there is no repository, the file
    /// lives outside it, the buffer is dirty (blame would be stale against
    /// unsaved edits — the data-safety reason inline blame never runs
    /// between keystrokes), or the document is guard-suppressed (the same
    /// large/pathological-file guard that suppresses syntax and symbols).
    func inlineBlame(for document: EditorDocument) async -> GitBlame? {
        guard isInlineBlameEnabled else { return nil }
        return await blame(for: document)
    }

    // MARK: - Issue #15: full-file blame

    /// Toggles the full-file blame decoration (issue #15): every committed
    /// AND uncommitted line gets its own "Author, relative-date" annotation,
    /// not just the caret's current line. A separate per-window toggle from
    /// GX1 inline blame — either can be on independently — but both share
    /// `blame(for:)`'s cache and git plumbing, so enabling this never spawns
    /// a second, redundant `git blame` process for the same buffer state.
    /// Off by default; not persisted (same calm-default precedent as
    /// `toggleInlineBlame()`).
    func toggleFileBlameAnnotations() {
        isFileBlameAnnotationsEnabled.toggle()
        if !isFileBlameAnnotationsEnabled { inlineBlameStore.invalidate() }
    }

    /// Computes (or returns the cached) `GitBlame` for `document`'s full-file
    /// blame decoration. Same guards, cache, and git plumbing as
    /// `inlineBlame(for:)` — gated on `isFileBlameAnnotationsEnabled`
    /// instead of `isInlineBlameEnabled` so the two decorations toggle
    /// independently.
    func fileBlameAnnotations(for document: EditorDocument) async -> GitBlame? {
        guard isFileBlameAnnotationsEnabled else { return nil }
        return await blame(for: document)
    }

    /// Shared blame lookup behind both GX1 inline blame and issue #15's
    /// full-file blame: `nil` — no process spawned, no cache touched — when
    /// there is no repository, the file lives outside it, the buffer is
    /// dirty (blame would be stale against unsaved edits — the data-safety
    /// reason neither decoration ever runs between keystrokes), or the
    /// document is guard-suppressed (the same large/pathological-file guard
    /// that suppresses syntax and symbols). Cached by (repo-relative path,
    /// HEAD OID, buffer revision) so both callers reuse one fetch.
    private func blame(for document: EditorDocument) async -> GitBlame? {
        guard !document.isDirty, !document.suppressesSyntax,
            let gitSnapshot, let repositoryRoot = gitSnapshot.repositoryRoot ?? rootURL,
            let relativePath = gitRepositoryRelativePath(for: document)
        else { return nil }

        let key = InlineBlameCacheKey(
            path: relativePath, headOID: gitSnapshot.headOID, revision: document.revision)
        if let cached = inlineBlameStore.blame(for: key) { return cached }
        do {
            let blame = try await gitService.blame(
                forRelativePath: relativePath, at: repositoryRoot)
            inlineBlameStore.store(blame, for: key)
            return blame
        } catch {
            return nil
        }
    }

    // MARK: - AI inline completion

    /// Toggles the per-window AI tab-completion mode (Edit menu / palette).
    /// Off by default and not persisted: enabling it is the explicit consent
    /// to send a bounded window of buffer text around the caret to the
    /// configured AI provider (AGENTS: AI stays explicit).
    func toggleAICompletion() {
        guard Self.isAICompletionFeatureAvailable else { return }
        isAICompletionEnabled.toggle()
    }

    /// Resolves one inline-completion suggestion for the bounded context
    /// around the caret. Silent by design: any failure (no provider
    /// configured, no key, network, over-budget reply) returns nil — a
    /// completion must never interrupt typing with an alert.
    func inlineCompletion(prefix: String, suffix: String, fileName: String) async -> String? {
        guard isAICompletionEnabled else { return nil }
        do {
            let configurations = try await aiConfigurationStore.load()
            let preferredID = await aiConfigurationStore.selectedConfigurationID()
            guard
                let configuration = preferredID.flatMap({ id in
                    configurations.first(where: { $0.id == id })
                }) ?? configurations.first,
                let apiKey = try await aiSecretStore.secret(for: configuration.id)
            else { return nil }

            let stream = try aiProviderClient.makeTextStream(
                configuration: configuration,
                apiKey: apiKey,
                instructions: AICompletionPromptBuilder.instructions,
                prompt: AICompletionPromptBuilder.prompt(
                    prefix: prefix, suffix: suffix, fileName: fileName)
            )
            var output = ""
            for try await delta in stream {
                try Task.checkCancellation()
                output += delta
                // Completions are short by contract; stop consuming once the
                // reply clearly exceeds any usable suggestion.
                if output.count > AICompletionPromptBuilder.maximumSuggestionCharacters * 2 {
                    break
                }
            }
            return AICompletionPromptBuilder.sanitize(output)
        } catch {
            return nil
        }
    }

    // MARK: - GX2 hunk peek / blame hover

    /// The working-tree diff for `document`, used by the GX2 hunk-peek
    /// popover. Cached by (repo-relative path, buffer revision) — a single
    /// entry, mirroring `InlineBlameStore`'s "active file only" retention —
    /// so opening the peek repeatedly at the same buffer state never
    /// re-diffs.
    func workingTreeDiff(for document: EditorDocument) async -> GitFileDiff? {
        guard let rootURL, let relativePath = gitRepositoryRelativePath(for: document) else {
            return nil
        }
        let key = WorkingTreeDiffCacheKey(path: relativePath, revision: document.revision)
        if let cached = workingTreeDiffCache, cached.key == key { return cached.diff }
        do {
            let diff = try await gitService.diff(
                GitDiffRequest(path: relativePath, scope: .workingTree), at: rootURL)
            workingTreeDiffCache = (key, diff)
            return diff
        } catch {
            return nil
        }
    }

    /// Stages one hunk sliced from the peek popover's working-tree diff —
    /// the same `GitHunkPatchBuilder` + `applyHunk(staging:true)` path
    /// `stageHunk(_:)` uses for the standalone diff canvas, but keyed to
    /// `diff` directly rather than `gitOpenDiff`: the peek can stage without
    /// the diff canvas ever being open. A context drift since the diff was
    /// captured throws `GitServiceError.hunkContextChanged`, which surfaces
    /// through the normal Git error alert rather than silently retrying
    /// against a stale hunk.
    func stagePeekHunk(_ hunk: GitDiffHunk, in diff: GitFileDiff) async {
        guard let rootURL, !isGitBusy, !isGitHunkActionBusy else { return }
        isGitHunkActionBusy = true
        defer { isGitHunkActionBusy = false }
        do {
            let patch = try GitHunkPatchBuilder.patch(for: hunk, in: diff)
            try await gitService.applyHunk(patch: patch, staging: true, at: rootURL)
            workingTreeDiffCache = nil
            await refreshGit()
        } catch is CancellationError {
            return
        } catch {
            reportGitError(error)
        }
    }

    /// Opens the standalone diff canvas for `document`'s working-tree
    /// change — the peek popover's "Open Full Diff" action. A no-op when
    /// the file has no working-tree change to show.
    func openWorkingTreeDiff(for document: EditorDocument) {
        guard let relativePath = gitRepositoryRelativePath(for: document),
            let change = gitSnapshot?.changes.first(where: { $0.path == relativePath })
        else { return }
        Task { await gitOpenChangeDiff(change, scope: .workingTree) }
    }

    /// Opens the GX2 hunk-peek popover at the selected document's caret
    /// line — the "Peek Change at Line" command's session-level entry point.
    /// A no-op when there is no mounted editor to peek in.
    func peekChangeAtCaret() {
        selectedDocument?.peekChangeAtCaretAction?()
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

    /// Explicit `git init` from the Source Control empty state — the only
    /// way Rafu ever creates a repository (never automatic, AGENTS: Git
    /// stays explicit). On success the refreshed snapshot flips the panel
    /// from the empty state to the full inspector.
    func gitInitializeRepository() async {
        guard let rootURL else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            try await gitService.initializeRepository(at: rootURL)
            await refreshWorkspace()
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
            gitLastFetchedAt = Date()
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

    /// Whether "Publish to GitHub…" can run right now: a Git repository is
    /// open, it has at least one commit (`gh repo create … --push` has
    /// nothing to push from an unborn HEAD), and no `origin` remote already
    /// exists.
    var canPublishToGitHub: Bool {
        guard let gitSnapshot else { return false }
        return !gitSnapshot.isUnborn && !gitRemoteNames.contains("origin")
    }

    /// Publishes the open workspace as a new GitHub repository: creates it,
    /// adds it as `origin`, and pushes the current branch — the
    /// `GitHubPublishSheet`'s explicit "Create & Push" confirmation. A no-op
    /// unless `canPublishToGitHub` holds and no publish is already running.
    func publishToGitHub(name: String, visibility: GitHubRepositoryVisibility) async {
        guard let rootURL, canPublishToGitHub, !isPublishingToGitHub else { return }
        isPublishingToGitHub = true
        defer { isPublishingToGitHub = false }
        do {
            try await GitHubCLIService().publish(name: name, visibility: visibility, at: rootURL)
            isGitHubPublishPresented = false
            await refreshGit()
            await GitHubAccountModel.shared.refresh()
        } catch {
            reportGitError(error)
        }
    }

    /// Starts an AI ignore-file suggestion as an owned, cancellable task —
    /// mirrors `startAICommitGeneration()`. Presents `IgnoreSuggestionSheet`
    /// immediately (before the AI reply arrives) so it can show its loading
    /// state; a no-op while a suggestion is already in flight.
    func startIgnoreSuggestion(kind: IgnoreFileKind) {
        guard ignoreSuggestionTask == nil else { return }
        ignoreSuggestion = nil
        ignoreSuggestionError = nil
        isIgnoreSuggestionPresented = true
        ignoreSuggestionTask = Task(name: "Suggest \(kind.fileName)") { [weak self] in
            await self?.suggestIgnoreFile(kind: kind)
            self?.ignoreSuggestionTask = nil
        }
    }

    /// Cancels an in-flight suggestion request and dismisses
    /// `IgnoreSuggestionSheet` — its Cancel action and interactive dismissal
    /// alike, mirroring `cancelAICommitGeneration()`.
    func cancelIgnoreSuggestion() {
        ignoreSuggestionTask?.cancel()
        ignoreSuggestionTask = nil
        isSuggestingIgnore = false
        isIgnoreSuggestionPresented = false
        ignoreSuggestion = nil
        ignoreSuggestionError = nil
    }

    /// Sends only the bounded workspace file tree (relative paths, never
    /// file contents — see `IgnoreFileTreeSerializer`) plus the existing
    /// ignore file's own content to the configured AI provider, and parses
    /// its reply into `ignoreSuggestion` for the sheet to present. Errors
    /// are bounded exactly like `generateAICommitMessage()`.
    func suggestIgnoreFile(kind: IgnoreFileKind) async {
        guard !isSuggestingIgnore else { return }
        isSuggestingIgnore = true
        ignoreSuggestionError = nil
        defer { isSuggestingIgnore = false }

        do {
            try Task.checkCancellation()
            guard let rootURL else {
                throw AIProviderError.invalidConfiguration("Open a folder first.")
            }

            ensureFileIndexReady()
            let paths = try await queryFileIndex(term: "", limit: 5_000)
            let existingURL = rootURL.appending(path: kind.fileName)
            let existingContent = (try? await fileService.readText(at: existingURL)) ?? ""
            let tree = IgnoreFileTreeSerializer.serialize(paths: paths)

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

            let promptBuilder = IgnoreSuggestionPromptBuilder()
            let stream = try aiProviderClient.makeTextStream(
                configuration: configuration,
                apiKey: apiKey,
                instructions: promptBuilder.instructions(for: kind),
                prompt: promptBuilder.makePrompt(
                    kind: kind, tree: tree, existingContent: existingContent)
            )
            var accumulated = ""
            for try await delta in stream {
                try Task.checkCancellation()
                accumulated += delta
            }
            guard !accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                ignoreSuggestionError = "The provider returned an empty reply — try again."
                return
            }

            let proposed = IgnoreSuggestionResponseParser.parse(accumulated, kind: kind)
            ignoreSuggestion = IgnoreSuggestionState(
                kind: kind, proposed: proposed, editableContent: proposed.content
            )
        } catch is CancellationError {
            return
        } catch {
            ignoreSuggestionError = Self.boundedAIErrorMessage(error)
        }
    }

    /// Writes the (possibly user-edited) accepted ignore-file content
    /// atomically and re-syncs workspace/Git state — `IgnoreSuggestionSheet`'s
    /// Accept action.
    func acceptIgnoreSuggestion(content: String) async {
        guard let rootURL, let kind = ignoreSuggestion?.kind else { return }
        do {
            try await fileService.writeText(content, to: rootURL.appending(path: kind.fileName))
            ignoreSuggestion = nil
            ignoreSuggestionError = nil
            isIgnoreSuggestionPresented = false
            await refreshWorkspace()
            await refreshGit()
        } catch {
            reportOpenFolderError(error)
        }
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

    /// Pure, per-render heuristic scan of the staged changeset — the commit
    /// composer's advisory-only warning (`GitInspectorView.commitComposer`).
    /// Never blocks a commit; see `CommitHygieneChecker`.
    var commitHygieneFindings: [CommitHygieneFinding] {
        CommitHygieneChecker.findings(for: gitSnapshot?.stagedChanges.map(\.path) ?? [])
    }

    /// Starts AI commit-message generation as an owned, cancellable task — the
    /// composer's "Generate Commit Message" action. A no-op while a
    /// generation is already in flight, mirroring `generateAICommitMessage`'s
    /// own re-entrancy guard. Pair with `cancelAICommitGeneration()` (the
    /// composer's Stop button).
    func startAICommitGeneration() {
        guard aiCommitGenerationTask == nil else { return }
        aiCommitGenerationTask = Task(name: "Generate AI commit message") { [weak self] in
            await self?.generateAICommitMessage()
            self?.aiCommitGenerationTask = nil
        }
    }

    /// Stops an in-flight AI commit-message generation — the composer's Stop
    /// button. Cancelling the task lets `generateAICommitMessage()`'s
    /// `Task.checkCancellation()` calls unwind the streaming loop; clearing
    /// `isGeneratingAICommitMessage` here too means the UI drops the
    /// generating state immediately rather than waiting on that unwind.
    func cancelAICommitGeneration() {
        aiCommitGenerationTask?.cancel()
        aiCommitGenerationTask = nil
        isGeneratingAICommitMessage = false
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
        teardownTerminalGroups()
        languageIntelligence.workspaceDidClose()
        stopAccessingSecurityScopedURL()
        TerminalAttentionCenter.shared.unregister(self)
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
            beginTerminalGroupLibrary(for: resolved.url)
            if !restored.terminalGroupRestorationDiagnostics.isEmpty {
                // Do not disclose a path, saved name, or malformed payload.
                // This fixed bounded notice survives the first successful
                // library list so a damaged sibling field remains visible.
                terminalGroupRestorationError = "One saved Terminal Group could not be restored."
                terminalGroupStoreError = terminalGroupRestorationError
            }
            navigatorMode = restored.navigatorMode
            workspaceSearch.loadHistory(for: resolved.url)
            resetFileTreeState()
            startFileWatcher()
            await refreshWorkspace()

            languageIntelligence.workspaceDidOpen(root: resolved.url)
            reloadConductorRuns(for: resolved.url)
            for relativePath in restored.openRelativePaths {
                let url = resolved.url.appending(path: relativePath)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                _ = trackNewDocument(url: url)
            }
            await restoreTerminalGroupInstances(
                restored.terminalGroupRestoration, rootURL: resolved.url)
            restoreEditorLayout(
                restored.editorLayout, terminalGroups: restored.terminalGroupRestoration,
                from: restored.rootPath, to: resolved.url)
            if let selected = restored.selectedRelativePath,
                let document = openDocuments.first(where: {
                    relativePath(for: $0.url) == selected
                })
            {
                select(document)
            } else if !hasAnyEditorTabs, let first = openDocuments.first {
                select(first)
            } else {
                synchronizeSelectionFromLayout()
            }
            applyRestoredHibernationPlaceholders()

            if resolved.isStale { persistWorkspaceState() }
        } catch {
            await restorationStore.clear()
        }
    }

    private func restoreTerminalGroupInstances(
        _ restoration: TerminalGroupWorkspaceRestoration?, rootURL: URL
    ) async {
        guard let restoration else { return }
        let key = TerminalGroupWorkspaceKey(standardizedRoot: rootURL)
        let generation = terminalGroupWorkspaceGeneration
        do {
            let store = await resolvedTerminalGroupSavedLayoutStore()
            let records = try await store.listSavedLayouts(for: key)
            guard terminalGroupWorkspaceGeneration == generation,
                self.rootURL.map({ TerminalGroupWorkspaceKey(standardizedRoot: $0) }) == key
            else { return }
            let savedIDs = Set(records.map(\.id))
            for record in restoration.openGroups {
                guard let savedLayoutID = record.savedLayoutID, savedIDs.contains(savedLayoutID)
                else {
                    continue
                }
                do {
                    let decoded = try terminalGroupCodec(for: rootURL).restoreOpenInstance(record)
                    _ = try terminal.insertInertSnapshot(decoded.snapshot)
                } catch {
                    // The sibling file tabs remain valid. A corrupt group is
                    // intentionally dropped as one bounded restoration unit.
                    terminalGroupRestorationError =
                        "One saved Terminal Group could not be restored."
                    terminalGroupStoreError = terminalGroupRestorationError
                }
            }
        } catch {
            guard terminalGroupWorkspaceGeneration == generation,
                self.rootURL.map({ TerminalGroupWorkspaceKey(standardizedRoot: $0) }) == key
            else { return }
            terminalGroupStoreError = "Saved Terminal Groups could not be loaded."
        }
    }

    private func terminalGroupCodec(for workspaceRoot: URL) -> TerminalGroupRestorationCodec {
        let root = workspaceRoot.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.path
        let approvedShellPaths = Set(availableTerminalShells.map(\.path))
        return TerminalGroupRestorationCodec { profile in
            let folder = root.appending(path: profile.startingFolder.rawValue)
                .resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                isDirectory.boolValue,
                FileManager.default.isReadableFile(atPath: folder.path),
                folder.path == rootPath || folder.path.hasPrefix(rootPath + "/")
            else { return .missingFolder }
            switch profile.shell {
            case .preferredShell:
                return approvedShellPaths.isEmpty ? .unapprovedShell : .available
            case .approvedShellPath(let path):
                return approvedShellPaths.contains(path) ? .available : .unapprovedShell
            }
        }
    }

    private func persistWorkspaceState() {
        guard let rootURL else { return }
        let openPaths = openDocuments.map { relativePath(for: $0.url) }
        let selectedPath = selectedDocument.map { relativePath(for: $0.url) }
        let navigatorMode = navigatorMode
        let terminalGroupRestoration = terminalGroupWorkspaceRestoration()
        let restorableEditorLayout = editorLayoutForWorkspaceRestoration()
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
                        editorLayout: EditorLayoutRestoration(layout: restorableEditorLayout),
                        terminalGroupRestoration: terminalGroupRestoration
                    )
                )
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func terminalGroupWorkspaceRestoration() -> TerminalGroupWorkspaceRestoration? {
        let records: [TerminalGroupOpenTabRestorationRecord] = terminal.terminalGroups.compactMap {
            snapshot in
            guard snapshot.savedLayoutID != nil, presentedTerminalGroupIDs.contains(snapshot.id)
            else {
                return nil
            }
            let panes: [TerminalGroupOpenPaneRestorationRecord] = snapshot.panes.compactMap {
                pane in
                let kind: SavedTerminalPaneKind
                switch pane.runtimeKind {
                case .ordinaryShell: kind = .ordinaryShell
                case .directAgentTerminal, .unavailableAgentTerminal:
                    kind = .unavailableAgentTerminal
                case .ensembleRole, .ensembleCoordinator, .unavailableEnsemble:
                    kind = .unavailableEnsemble
                }
                return try? TerminalGroupOpenPaneRestorationRecord(
                    id: pane.id, explicitUserName: pane.explicitUserName,
                    themeColor: pane.themeColor, kind: kind,
                    launchProfile: kind == .ordinaryShell ? pane.launchProfile : nil)
            }
            guard panes.count == snapshot.panes.count else { return nil }
            return try? TerminalGroupOpenTabRestorationRecord(
                groupID: snapshot.id, name: snapshot.name, root: snapshot.root,
                focusedPaneID: snapshot.focusedPaneID, savedLayoutID: snapshot.savedLayoutID,
                panes: panes)
        }
        return try? TerminalGroupWorkspaceRestoration(openGroups: records)
    }

    /// Filters a value copy only. Unsaved groups and every legacy live
    /// terminal remain usable in this window but never enter the workspace
    /// restoration payload.
    private func editorLayoutForWorkspaceRestoration() -> EditorLayoutState {
        var layout = editorLayout
        for editorGroupID in layout.groupIDs {
            for tab in layout.group(id: editorGroupID)?.tabs ?? [] {
                let retain: Bool
                switch tab.resource {
                case .file: retain = true
                case .terminalGroup(let groupID):
                    retain = terminal.terminalGroup(groupID)?.savedLayoutID != nil
                case .terminal, .restorable: retain = false
                }
                if !retain { _ = layout.closeTab(tab.id) }
            }
        }
        layout.collapseEmptyGroups()
        return layout
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
        gitWorktrees = []
        gitSelectedChangeIDs = []
        gitBranchSnapshot = nil
        gitHistoryPage = nil
        gitSelectedHistoryCommitID = nil
        gitHistoryCommitChanges = []
        isGitHistoryDetailLoading = false
        gitOpenDiff = nil
        gitMergeState = nil
        gitLastFetchedAt = nil
        inlineBlameStore.invalidate()
        workingTreeDiffCache = nil
    }

    private static func boundedAIErrorMessage(_ error: any Error) -> String {
        let message =
            (error as? LocalizedError)?.errorDescription
            ?? "Commit-message generation failed."
        return String(decoding: message.utf8.prefix(512), as: UTF8.self)
    }

    /// Same `String(decoding:as:)`-on-a-UTF-8-prefix idiom as
    /// `boundedAIErrorMessage` above (and `TerminalAttentionPolicy`'s
    /// private `boundedUTF8`) — truncating on a byte boundary repairs an
    /// incomplete trailing multibyte sequence into one replacement
    /// character rather than corrupting further bytes. 200 bytes mirrors
    /// `TerminalAttentionPolicy.snippet`'s per-line cap: plenty for a HUD
    /// pill or notification title, nowhere near the 1 MiB per-FILE cap that
    /// bounds a `.rafu/agents|workflows/*.md` frontmatter field.
    private static func boundedConductorAttentionString(
        _ text: String, maxBytes: Int = 200
    ) -> String {
        String(decoding: text.utf8.prefix(maxBytes), as: UTF8.self)
    }

    private func synchronizeSelectionFromLayout(fallback: EditorDocument? = nil) {
        let group = editorLayout.group(id: editorLayout.focusedGroupID)
        let selectedTab = group?.selectedTabID.flatMap { tabID in
            group?.tabs.first(where: { $0.id == tabID })
        }
        if case .terminal(let sessionID) = selectedTab?.resource {
            selectedDocumentID = nil
            selectedTreePath = nil
            terminal.selectedID = sessionID
            // Bell-clear hook 2/3 (terminal-manager.md T-E) — this is the
            // path reveal/split/drag/close-neighbour funnel through, not
            // just direct tab clicks (`selectEditorTab`).
            terminal.sessions.first(where: { $0.id == sessionID })?.clearAttention()
            return
        }
        if case .terminalGroup(let groupID) = selectedTab?.resource,
            let paneID = terminal.terminalGroup(groupID)?.focusedPaneID
        {
            selectedDocumentID = nil
            selectedTreePath = nil
            terminal.selectedID = terminal.terminalController(for: paneID)?.id
            terminal.terminalController(for: paneID)?.clearAttention()
            terminalGroupFocusRequest &+= 1
            return
        }
        let document = selectedTab.flatMap(document(for:)) ?? fallback
        selectedDocumentID = document?.id
        selectedTreePath = document?.url.path
    }

    private func restoreEditorLayout(
        _ restoration: EditorLayoutRestoration?,
        terminalGroups: TerminalGroupWorkspaceRestoration? = nil,
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
                switch tab.resource.restorationClassification(terminalGroups: terminalGroups) {
                case .file:
                    guard case .file(let savedURL) = tab.resource,
                        let rebasedURL = rebase(savedURL, from: oldRootURL, to: newRootURL),
                        openURLs.contains(rebasedURL.resolvingSymlinksInPath().standardizedFileURL)
                    else {
                        _ = layout.closeTab(tab.id)
                        continue
                    }
                    layout.updateResource(for: tab.id, to: .file(rebasedURL))
                case .terminalGroupRecord(let terminalGroupID):
                    // The envelope record alone is insufficient: only retain
                    // the tab if its inert runtime snapshot was accepted.
                    guard terminal.terminalGroup(terminalGroupID) != nil else {
                        _ = layout.closeTab(tab.id)
                        continue
                    }
                case .missingTerminalGroupRecord, .notRestorable:
                    _ = layout.closeTab(tab.id)
                }
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
