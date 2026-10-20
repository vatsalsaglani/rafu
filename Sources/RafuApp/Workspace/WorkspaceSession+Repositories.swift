import Foundation
import RafuCore

/// Several Git repositories in one workspace: each root inside a Git work
/// tree, and the nested repositories directly inside a root.
///
/// Source Control shows one selected repository in full (`gitRootURL`).
/// The Repositories section lists every repository with a small summary
/// (branch, ahead/behind, change count) from one
/// `git status --porcelain=v2 --branch` run each. Summaries are never
/// polled. They are fetched when the section is visible and the list
/// changes, on Refresh, when FSEvents show that a repository changed, and
/// once for the repository of the selected editor file. No Git process
/// stays alive.
extension WorkspaceSession {
    // MARK: - Selection

    /// The ID of the repository Source Control shows. With no explicit
    /// choice it is the primary root.
    var effectiveSourceControlRepositoryID: String? {
        if let id = sourceControlRepositoryID { return id }
        return rootURL.map(GitRepositoryRef.identifier(for:))
    }

    /// The listed repository Source Control shows, if it is listed.
    var selectedGitRepository: GitRepositoryRef? {
        guard let id = effectiveSourceControlRepositoryID else { return nil }
        return gitRepositories.first { $0.id == id }
    }

    /// The folder Source Control and the file-tree Git badges work on.
    var gitRootURL: URL? {
        guard let id = sourceControlRepositoryID else { return rootURL }
        if let repository = gitRepositories.first(where: { $0.id == id }) {
            return repository.url
        }
        // A root chosen before discovery finished, or one that is not a
        // repository (Source Control then offers to initialize it).
        if let root = rootMatching(repositoryID: id) { return url(forRoot: root.id) }
        return rootURL
    }

    /// The root whose Files-tree rows get Git badges: the root that holds
    /// the Source Control repository.
    var effectiveSourceControlRootID: UUID? {
        if let repository = selectedGitRepository { return repository.rootID }
        if let id = sourceControlRepositoryID, let root = rootMatching(repositoryID: id) {
            return root.id
        }
        return descriptor?.id
    }

    /// The folder file-tree Git badges are relative to.
    var gitBadgeRootURL: URL? {
        effectiveSourceControlRootID.flatMap { url(forRoot: $0) } ?? rootURL
    }

    /// Compatibility view of the selection as a root: the chosen root when
    /// Source Control shows a root-level repository other than the primary
    /// root, otherwise nil. Setting it selects that root.
    var sourceControlRootID: UUID? {
        get {
            guard let id = sourceControlRepositoryID,
                let root = rootMatching(repositoryID: id), root.id != descriptor?.id
            else { return nil }
            return root.id
        }
        set {
            guard let newValue, newValue != descriptor?.id, let url = url(forRoot: newValue)
            else {
                sourceControlRepositoryID = nil
                return
            }
            sourceControlRepositoryID = GitRepositoryRef.identifier(for: url)
        }
    }

    /// Roots that are Git work trees (for the Files-tree root menu).
    var sourceControlRootChoices: [WorkspaceRoot] {
        let rootIDs = Set(gitRepositories.filter { !$0.isNested }.map(\.rootID))
        return roots.filter { rootIDs.contains($0.id) }
    }

    /// The Git badge for a Files-tree row. Badges are keyed relative to the
    /// root that holds the Source Control repository, so rows of any other
    /// root show none. `rootID` nil means the primary root.
    func gitTreeBadge(forRelativePath path: String, rootID: UUID?) -> GitTreeBadge? {
        guard (rootID ?? descriptor?.id) == effectiveSourceControlRootID else { return nil }
        return gitTreeBadges[path]
    }

    func selectSourceControlRoot(_ id: UUID) {
        sourceControlRootID = id
    }

    /// Shows `repository` in Source Control. The primary root is stored as
    /// nil, so a one-folder workspace keeps its old state.
    func selectGitRepository(_ id: String) {
        let primaryID = rootURL.map(GitRepositoryRef.identifier(for:))
        sourceControlRepositoryID = id == primaryID ? nil : id
    }

    private func rootMatching(repositoryID id: String) -> WorkspaceRoot? {
        roots.first { root in
            url(forRoot: root.id).map(GitRepositoryRef.identifier(for:)) == id
        }
    }

    // MARK: - Discovery

    /// Re-finds the repositories of every root, off the main actor.
    func refreshGitRepositoryRoots() {
        repositoryDiscoveryTask?.cancel()
        repositoryDiscoveryTask = Task(name: "Find Git repositories") { [weak self] in
            await self?.reloadGitRepositories()
        }
    }

    /// Discovery itself; awaitable for tests. A result for an old root list
    /// is dropped.
    func reloadGitRepositories() async {
        let roots = roots
        guard !roots.isEmpty else {
            applyGitRepositories([])
            return
        }
        let names = rootDisplayNames
        let inputs = roots.compactMap { root in
            url(forRoot: root.id).map {
                WorkspaceGitRepositories.RootInput(
                    id: root.id, url: $0, label: names[root.id] ?? root.name)
            }
        }
        let found = await WorkspaceGitRepositories.discover(inputs)
        guard !Task.isCancelled, self.roots.map(\.id) == roots.map(\.id) else { return }
        applyGitRepositories(found)
    }

    private func applyGitRepositories(_ repositories: [GitRepositoryRef]) {
        if gitRepositories != repositories { gitRepositories = repositories }
        let ids = Set(repositories.map(\.id))
        let kept = gitRepositorySummaries.filter { ids.contains($0.key) }
        if kept.count != gitRepositorySummaries.count { gitRepositorySummaries = kept }
        pendingRepositorySummaryIDs.formIntersection(ids)
        staleRepositorySummaryIDs.formIntersection(ids)
        // Each watcher asks a nested repository about ignored paths with
        // that repository's own rules.
        let primaryID = descriptor?.id
        setPrimaryNestedRepositoryPaths(
            repositories.filter { $0.rootID == primaryID && $0.isNested }.map(\.relativePath))
        for tree in additionalRootTrees {
            tree.setNestedRepositoryPaths(
                repositories.filter { $0.rootID == tree.id && $0.isNested }.map(\.relativePath))
        }
        // A nested repository that is gone falls back to the primary root.
        if let id = sourceControlRepositoryID, !ids.contains(id),
            rootMatching(repositoryID: id) == nil
        {
            sourceControlRepositoryID = nil
        }
        // With no explicit choice and a primary root that is not a
        // repository, show the first repository instead of an empty panel.
        if sourceControlRepositoryID == nil, let first = repositories.first,
            let primaryID = effectiveSourceControlRepositoryID, !ids.contains(primaryID)
        {
            sourceControlRepositoryID = first.id
        }
        recordSelectedRepositorySummary()
        noteActiveDocumentRepository()
        if isRepositoriesSectionVisible { refreshMissingRepositorySummaries() }
    }

    /// Drops the repositories of a removed root at once (discovery is not
    /// needed to forget them).
    func dropGitRepositories(inRoot rootID: UUID) {
        let selectedRootID = selectedGitRepository?.rootID
        applyGitRepositories(gitRepositories.filter { $0.rootID != rootID })
        if selectedRootID == rootID || sourceControlRootID == rootID {
            sourceControlRepositoryID = nil
        }
    }

    func resetGitRepositoryState() {
        repositoryDiscoveryTask?.cancel()
        repositoryDiscoveryTask = nil
        repositorySummaryTask?.cancel()
        repositorySummaryTask = nil
        pendingRepositorySummaryIDs = []
        staleRepositorySummaryIDs = []
        if !gitRepositories.isEmpty { gitRepositories = [] }
        if !gitRepositorySummaries.isEmpty { gitRepositorySummaries = [:] }
        if activeDocumentRepositoryID != nil { activeDocumentRepositoryID = nil }
    }

    /// A change batch can add or remove a repository: a `.git` appears in a
    /// root (`git init`) or in a child folder (a clone), or a storm moved
    /// many files. Discovery runs again only then.
    func noteRepositoryListMayHaveChanged(_ changes: WorkspaceChangeSet, rootID: UUID) {
        let listed = gitRepositories.filter { $0.rootID == rootID }
        let rootListed = listed.contains { !$0.isNested }
        let nestedListed = Set(listed.filter(\.isNested).map(\.relativePath))
        let unknownNested = changes.nestedGitChangedDirectories.contains { folder in
            !folder.contains("/") && !nestedListed.contains(folder)
        }
        if changes.isStorm || (changes.gitChanged && !rootListed) || unknownNested {
            refreshGitRepositoryRoots()
        }
    }

    /// The repositories of `rootID` for routing a change batch. A root the
    /// user chose that is not (yet) listed still counts, so its Source
    /// Control view stays live, as it did before discovery existed.
    func repositoriesForChangeRouting(rootID: UUID) -> [GitRepositoryRef] {
        var repositories = gitRepositories.filter { $0.rootID == rootID }
        if !repositories.contains(where: { !$0.isNested }),
            effectiveSourceControlRootID == rootID, selectedGitRepository == nil,
            let url = url(forRoot: rootID)
        {
            repositories.append(GitRepositoryRef(rootID: rootID, url: url, displayName: ""))
        }
        return repositories
    }

    // MARK: - Summaries

    /// The summary for a repository: the selected one follows the full
    /// Source Control snapshot.
    func gitRepositorySummary(for id: String) -> GitRepositorySummary? {
        gitRepositorySummaries[id]
    }

    /// Keeps the selected repository's summary in step with `gitSnapshot`,
    /// with no extra Git process.
    func recordSelectedRepositorySummary() {
        guard let snapshot = gitSnapshot, let repository = selectedGitRepository else { return }
        let summary = GitRepositorySummary(snapshot)
        if gitRepositorySummaries[repository.id] != summary {
            gitRepositorySummaries[repository.id] = summary
        }
        staleRepositorySummaryIDs.remove(repository.id)
    }

    /// The Repositories section appeared, or the list changed while it is
    /// visible: fetch what is missing or stale.
    func repositoriesSectionDidAppear() {
        isRepositoriesSectionVisible = true
        refreshMissingRepositorySummaries()
    }

    func repositoriesSectionDidDisappear() {
        isRepositoriesSectionVisible = false
    }

    private func refreshMissingRepositorySummaries() {
        let missing = gitRepositories.map(\.id).filter { gitRepositorySummaries[$0] == nil }
        refreshRepositorySummaries(ids: staleRepositorySummaryIDs.union(missing))
    }

    /// FSEvents touched `ids`: fetch now when the section is visible,
    /// otherwise when it next appears. The active editor file's repository
    /// is fetched at once, because the status bar shows it.
    func noteRepositorySummariesChanged(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var now = ids.intersection([activeDocumentRepositoryID].compactMap { $0 })
        if isRepositoriesSectionVisible {
            now = ids
        } else {
            staleRepositorySummaryIDs.formUnion(ids.subtracting(now))
        }
        refreshRepositorySummaries(ids: now)
    }

    /// Fetches the summaries of `ids` (all listed repositories when nil).
    /// Requests coalesce: one task runs one `git status` at a time and
    /// drains the pending set, so a burst asks once per repository. The
    /// selected repository is skipped; its summary follows `gitSnapshot`.
    func refreshRepositorySummaries(ids: Set<String>? = nil) {
        let listed = Set(gitRepositories.map(\.id))
        var targets = (ids ?? listed).intersection(listed)
        if let selected = selectedGitRepository?.id, gitSnapshot != nil {
            targets.remove(selected)
        }
        guard !targets.isEmpty else { return }
        staleRepositorySummaryIDs.subtract(targets)
        pendingRepositorySummaryIDs.formUnion(targets)
        guard repositorySummaryTask == nil else { return }
        repositorySummaryTask = Task(name: "Refresh repository summaries") { [weak self] in
            await self?.drainRepositorySummaries()
        }
    }

    /// Source Control's Refresh: find repositories again (a new clone) and
    /// fetch every summary once.
    func refreshAllGitRepositories() {
        refreshRepositorySummaries()
        refreshGitRepositoryRoots()
    }

    /// The branch line for the status bar and the title bar before Source
    /// Control has loaded branches: the selected repository's summary. It
    /// comes from the `git status` snapshot that opening the workspace
    /// already runs (`refreshWorkspace()`), so no full Git refresh and no
    /// history load starts before Source Control is shown.
    var sourceControlBranchSummary: GitRepositorySummary? {
        if let id = selectedGitRepository?.id, let summary = gitRepositorySummaries[id] {
            return summary
        }
        return gitSnapshot.map(GitRepositorySummary.init)
    }

    /// The repository of the selected editor file when it is not the one
    /// Source Control shows, with its summary (for the status bar).
    var activeDocumentRepositoryOutsideSourceControl:
        (repository: GitRepositoryRef, summary: GitRepositorySummary)?
    {
        guard let repository = activeDocumentRepository,
            repository.id != effectiveSourceControlRepositoryID,
            let summary = gitRepositorySummaries[repository.id]
        else { return nil }
        return (repository, summary)
    }

    /// Awaitable for tests: waits for the summary task, if one runs.
    func awaitRepositorySummaries() async {
        await repositorySummaryTask?.value
    }

    private func drainRepositorySummaries() async {
        let service = GitService()
        // A cancelled task was already replaced by whoever cancelled it.
        defer { if !Task.isCancelled { repositorySummaryTask = nil } }
        var vanished = false
        while !Task.isCancelled, let id = pendingRepositorySummaryIDs.popFirst() {
            guard let repository = gitRepositories.first(where: { $0.id == id }) else { continue }
            let snapshot: GitSnapshot?
            do {
                snapshot = try await service.snapshot(at: repository.url)
            } catch {
                // A repository Git cannot read keeps its last summary.
                continue
            }
            guard !Task.isCancelled else { return }
            guard gitRepositories.contains(where: { $0.id == id }) else { continue }
            guard let snapshot else {
                // The folder is no longer a repository.
                gitRepositorySummaries[id] = nil
                vanished = true
                continue
            }
            let summary = GitRepositorySummary(snapshot)
            if gitRepositorySummaries[id] != summary { gitRepositorySummaries[id] = summary }
        }
        if vanished { refreshGitRepositoryRoots() }
    }

    // MARK: - Active editor file

    /// The listed repository that holds the selected editor file.
    var activeDocumentRepository: GitRepositoryRef? {
        guard let id = activeDocumentRepositoryID else { return nil }
        return gitRepositories.first { $0.id == id }
    }

    /// Tracks the repository of the selected editor file for the status
    /// bar, and fetches its summary once when the file moves to another
    /// repository. Source Control's selection never changes on its own.
    func noteActiveDocumentRepository() {
        guard gitRepositories.count > 1, let document = selectedDocument else {
            if activeDocumentRepositoryID != nil { activeDocumentRepositoryID = nil }
            return
        }
        let path = document.url.standardizedFileURL.path
        let id = WorkspaceGitRepositories.repository(containing: path, in: gitRepositories)?.id
        guard id != activeDocumentRepositoryID else { return }
        activeDocumentRepositoryID = id
        if let id, id != selectedGitRepository?.id,
            gitRepositorySummaries[id] == nil || staleRepositorySummaryIDs.contains(id)
        {
            refreshRepositorySummaries(ids: [id])
        }
    }
}
