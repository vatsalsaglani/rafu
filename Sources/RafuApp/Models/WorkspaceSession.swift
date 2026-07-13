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
    var fileTree: [WorkspaceFileNode] = []
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
    var gitSnapshot: GitSnapshot?
    var gitSelectedChangeIDs: Set<String> = []
    var gitBranchSnapshot: GitBranchSnapshot?
    var gitHistoryPage: GitHistoryPage?
    var gitSelectedHistoryCommitID: String?
    var gitHistoryCommitChanges: [GitCommitFileChange] = []
    var isGitHistoryDetailLoading = false
    var gitInspectorSection: GitInspectorSection = .changes
    var gitOpenDiff: GitOpenDiff?
    var gitMergeState: GitMergeState?
    var gitCommitMessage = ""
    var isGeneratingAICommitMessage = false
    var aiCommitGenerationError: String?
    var isLoadingTree = false
    var isGitBusy = false
    var isOpenFolderImporterPresented = false
    var isCommandPalettePresented = false
    var commandPaletteSeed = ""
    var isDocumentFindPresented = false
    var isDocumentReplacePresented = false
    var isQuitConfirmationPresented = false
    var cliInstallMessage: String?
    var isOpenFolderErrorPresented = false
    var openFolderErrorMessage = ""

    let workspaceSearch = WorkspaceSearchModel()

    @ObservationIgnored
    private var documentFindStates: [UUID: DocumentFindState] = [:]

    @ObservationIgnored
    private var securityScopedURL: URL?

    @ObservationIgnored
    private let fileService = WorkspaceFileService()

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
        NSLog("RAFU-DEBUG openLocalWorkspace: %@", url.path)
        guard url.startAccessingSecurityScopedResource() else {
            NSLog("RAFU-DEBUG scope access DENIED for: %@", url.path)
            reportOpenFolderError(WorkspaceOpenError.securityScopedAccessDenied)
            return
        }

        liveness.stop()
        let previousSecurityScopedURL = securityScopedURL
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent

        securityScopedURL = url
        descriptor = WorkspaceDescriptor(
            displayName: name,
            location: .local(LocalWorkspaceReference(path: url.path))
        )
        openDocuments = []
        editorLayout = EditorLayoutState()
        documentFindStates = [:]
        workspaceSearch.reset()
        workspaceSearch.loadHistory(for: url)
        selectedDocumentID = nil
        selectedTreePath = nil
        resetGitWorkbenchState()
        isTerminalPresented = false
        terminal.shutdownAll()
        RecentWorkspacesStore().record(url: url, displayName: name)
        Task { await refreshWorkspace() }
        startFileWatcher()
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
        if changes.treeChanged { await refreshWorkspace() }
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

    func refreshWorkspace() async {
        guard let rootURL else { return }
        isLoadingTree = true
        // The early cancellation return must still clear the loading flag or
        // the sidebar shows "Loading files…" forever after a superseded
        // refresh (e.g. rapid branch switches).
        defer { isLoadingTree = false }
        do {
            async let tree = fileService.tree(rootURL: rootURL)
            async let git = gitService.snapshot(at: rootURL)
            fileTree = try await tree
            gitSnapshot = try await git
            if gitSnapshot == nil { resetGitWorkbenchState() }
            reconcileGitSelection()
        } catch is CancellationError {
            return
        } catch {
            reportOpenFolderError(error)
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
            reportOpenFolderError(error)
        }
    }

    func open(_ node: WorkspaceFileNode) {
        guard !node.isDirectory else { return }
        if let existing = openDocuments.first(where: { $0.url == node.url }) {
            select(existing)
            return
        }
        let document = EditorDocument(url: node.url)
        openDocuments.append(document)
        documentFindStates[document.id] = DocumentFindState()
        select(document)
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
        synchronizeSelectionFromLayout(
            fallback: openDocuments.indices.contains(index)
                ? openDocuments[index] : openDocuments.last
        )
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

    func selectEditorTab(_ tabID: EditorTabID, in groupID: EditorGroupID) {
        guard let tab = editorLayout.group(id: groupID)?.tabs.first(where: { $0.id == tabID }),
            let document = document(for: tab)
        else { return }
        editorLayout.select(tabID, in: groupID)
        selectedDocumentID = document.id
        selectedTreePath = document.url.path
        persistWorkspaceState()
    }

    func splitEditorTab(_ tabID: EditorTabID, at edge: EditorSplitEdge) {
        guard let groupID = editorLayout.group(containing: tabID)?.id,
            editorLayout.split(group: groupID, at: edge, moving: tabID) != nil
        else { return }
        synchronizeSelectionFromLayout()
        persistWorkspaceState()
    }

    func moveEditorTab(_ tabID: EditorTabID, to groupID: EditorGroupID) {
        guard editorLayout.moveTab(tabID, to: groupID) else { return }
        synchronizeSelectionFromLayout()
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
            document = EditorDocument(url: url)
            openDocuments.append(document)
            documentFindStates[document.id] = DocumentFindState()
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
            document = EditorDocument(url: fileURL)
            openDocuments.append(document)
            documentFindStates[document.id] = DocumentFindState()
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
                        isDirectory: false,
                        children: nil
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
        } catch { reportOpenFolderError(error) }
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
        } catch { reportOpenFolderError(error) }
    }

    func stageAll() async {
        guard let rootURL else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            try await gitService.stageAll(at: rootURL)
            await refreshGit()
        } catch { reportOpenFolderError(error) }
    }

    func commit() async {
        guard let rootURL else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            _ = try await gitService.commit(message: gitCommitMessage, at: rootURL)
            gitCommitMessage = ""
            await refreshGit()
        } catch { reportOpenFolderError(error) }
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
                identity: "\(scopeTitle):\(change.path)"
            )
            selectedDocumentID = nil
            selectedTreePath = rootURL.appending(path: change.path).path
        } catch is CancellationError {
            return
        } catch {
            reportOpenFolderError(error)
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
            reportOpenFolderError(error)
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
                identity: "\(revision):\(change.path)"
            )
            selectedDocumentID = nil
            selectedTreePath = rootURL.appending(path: change.path).path
        } catch is CancellationError {
            return
        } catch {
            reportOpenFolderError(error)
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

    func gitCreateBranch(named name: String) async {
        guard let rootURL else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            try await gitService.createBranch(named: name, at: rootURL)
            await refreshGit()
        } catch { reportOpenFolderError(error) }
    }

    func gitCheckoutBranch(named name: String) async {
        guard let rootURL else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            try await gitService.checkout(branch: name, at: rootURL)
            await refreshWorkspace()
            await refreshGit()
        } catch { reportOpenFolderError(error) }
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
            reportOpenFolderError(error)
        }
    }

    func gitFetch(remote: String? = nil) async {
        guard let rootURL else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            _ = try await gitService.fetch(GitFetchRequest(remote: remote), at: rootURL)
            await refreshGit()
        } catch { reportOpenFolderError(error) }
    }

    func gitPull(strategy: GitPullStrategy = .merge) async {
        guard let rootURL else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            _ = try await gitService.pull(GitPullRequest(strategy: strategy), at: rootURL)
            await refreshWorkspace()
            await refreshGit()
        } catch { reportOpenFolderError(error) }
    }

    func gitPush(remote: String? = nil) async {
        guard let rootURL else { return }
        isGitBusy = true
        defer { isGitBusy = false }
        do {
            let request: GitPushRequest
            if let remote, let branch = gitBranchSnapshot?.currentBranch {
                request = GitPushRequest(
                    remote: remote,
                    branch: branch,
                    setUpstream: gitBranchSnapshot?.upstream == nil
                )
            } else {
                request = GitPushRequest()
            }
            _ = try await gitService.push(request, at: rootURL)
            await refreshGit()
        } catch { reportOpenFolderError(error) }
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

    func reportOpenFolderError(_ error: any Error) {
        // Superseded/cancelled tasks are routine (rapid refreshes during a
        // branch switch or FSEvents storm) and must never surface as a
        // user-facing failure alert.
        if error is CancellationError { return }
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        openFolderErrorMessage = error.localizedDescription
        isOpenFolderErrorPresented = true
    }

    isolated deinit {
        liveness.stop()
        restorationTask?.cancel()
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
            navigatorMode = restored.navigatorMode
            workspaceSearch.loadHistory(for: resolved.url)
            startFileWatcher()
            await refreshWorkspace()

            for relativePath in restored.openRelativePaths {
                let url = resolved.url.appending(path: relativePath)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let document = EditorDocument(url: url)
                openDocuments.append(document)
                documentFindStates[document.id] = DocumentFindState()
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
