import Foundation
import RafuCore
import Testing

@testable import RafuApp

@MainActor
@Suite("Multi-folder workspaces")
struct MultiFolderWorkspaceTests {
    @Test("Folders are added in order after the primary root, once each")
    func addFoldersInOrder() throws {
        let fixture = try MultiRootFixture()
        defer { fixture.remove() }
        let session = fixture.session

        #expect(session.roots.count == 1)
        #expect(!session.hasMultipleRoots)
        #expect(session.addFolder(at: fixture.lib))
        #expect(session.addFolder(at: fixture.docs))
        #expect(!session.addFolder(at: fixture.lib))
        #expect(!session.addFolder(at: fixture.primary))

        #expect(session.hasMultipleRoots)
        #expect(session.roots.map(\.name) == ["app", "lib", "docs"])
        #expect(session.roots.first?.id == session.descriptor?.id)
        #expect(session.rootURL?.standardizedFileURL == fixture.primary.standardizedFileURL)
    }

    @Test("The primary root cannot be removed; other roots can")
    func removeFolders() throws {
        let fixture = try MultiRootFixture()
        defer { fixture.remove() }
        let session = fixture.session
        session.addFolder(at: fixture.lib)
        session.addFolder(at: fixture.docs)
        let primaryID = try #require(session.descriptor?.id)
        let libID = try #require(session.roots.first { $0.name == "lib" }?.id)

        session.removeFolder(primaryID)
        #expect(session.roots.count == 3)
        session.removeFolder(libID)
        #expect(session.roots.map(\.name) == ["app", "docs"])
    }

    @Test("Paths carry the root name only when there is more than one root")
    func displayPaths() throws {
        let fixture = try MultiRootFixture()
        defer { fixture.remove() }
        let session = fixture.session
        let primaryFile = fixture.primary.appending(path: "README.md")
        #expect(session.displayPath(for: primaryFile) == "README.md")
        #expect(!session.isInAdditionalRoot(primaryFile))

        session.addFolder(at: fixture.lib)
        let libFile = fixture.lib.appending(path: "Sources/a.swift")
        #expect(session.displayPath(for: primaryFile) == "app/README.md")
        #expect(session.displayPath(for: libFile) == "lib/Sources/a.swift")
        #expect(session.isInAdditionalRoot(libFile))
        #expect(!session.isInAdditionalRoot(primaryFile))
    }

    @Test("Search covers every root and labels results by root")
    func searchRoots() throws {
        let fixture = try MultiRootFixture()
        defer { fixture.remove() }
        let session = fixture.session
        #expect(session.workspaceSearchRoots.map(\.label) == [nil])

        session.addFolder(at: fixture.lib)
        let roots = session.workspaceSearchRoots
        #expect(roots.map(\.label) == ["app", "lib"])
        #expect(roots.last?.url.standardizedFileURL == fixture.lib.standardizedFileURL)
    }

    @Test("Source Control follows the chosen root and badges only that root")
    func sourceControlRoot() throws {
        let fixture = try MultiRootFixture()
        defer { fixture.remove() }
        let session = fixture.session
        session.addFolder(at: fixture.lib)
        let libID = try #require(session.roots.last?.id)
        #expect(session.gitRootURL?.standardizedFileURL == fixture.primary.standardizedFileURL)
        #expect(session.effectiveSourceControlRootID == session.descriptor?.id)

        session.selectSourceControlRoot(libID)
        #expect(session.gitRootURL?.standardizedFileURL == fixture.lib.standardizedFileURL)
        #expect(session.effectiveSourceControlRootID == libID)
        #expect(session.gitTreeBadge(forRelativePath: "a.swift", rootID: nil) == nil)

        session.removeFolder(libID)
        #expect(session.sourceControlRootID == nil)
        #expect(session.gitRootURL?.standardizedFileURL == fixture.primary.standardizedFileURL)
    }

    @Test("A quick-open match from another root opens that root's file")
    func openMatchFromAnotherRoot() throws {
        let fixture = try MultiRootFixture()
        defer { fixture.remove() }
        let session = fixture.session
        session.addFolder(at: fixture.lib)
        let libID = try #require(session.roots.last?.id)

        session.openFile(
            WorkspaceFileMatch(
                rootID: libID, relativePath: "notes.txt", displayPath: "lib/notes.txt"))

        let document = try #require(session.selectedDocument)
        #expect(
            document.url.standardizedFileURL
                == fixture.lib.appending(path: "notes.txt").standardizedFileURL)
    }

    @Test("Workspace files are recognized by extension and get safe names")
    func workspaceFileNames() {
        #expect(WorkspaceSession.isWorkspaceFile(URL(filePath: "/tmp/Shop.rafuworkspace")))
        #expect(WorkspaceSession.isWorkspaceFile(URL(filePath: "/tmp/Shop.RafuWorkspace")))
        #expect(!WorkspaceSession.isWorkspaceFile(URL(filePath: "/tmp/Shop.json")))
        #expect(WorkspaceSession.workspaceFileName(for: "a/b:c") == "a-b-c.rafuworkspace")
        #expect(WorkspaceSession.workspaceFileName(for: "  ") == "Workspace.rafuworkspace")
    }

    @Test("Row text shows the folder count and paths")
    func rowPresentation() {
        let entry = SavedWorkspaceEntry(
            filePath: "/saved/Shop.rafuworkspace", displayName: "Shop",
            folderPaths: ["/work/web", "/work/api"], lastOpened: Date())
        let row = WorkspacesListRowPresentation.saved(entry)
        #expect(row.name == "Shop")
        #expect(row.folderCountText == "2 folders")
        #expect(row.pathsText == "/work/web, /work/api")
    }
}

@Suite("Multi-folder search and restoration values")
struct MultiFolderValueTests {
    private func result(_ path: String, matches: Int, truncated: Bool = false)
        -> WorkspaceSearchResult
    {
        let match = WorkspaceSearchMatch(
            range: NSRange(location: 0, length: 1), line: 1, column: 1, preview: "x")
        var statistics = WorkspaceSearchStatistics()
        statistics.searchedFiles = 1
        return WorkspaceSearchResult(
            groups: [
                WorkspaceSearchFileGroup(
                    fileURL: URL(filePath: "/r/\(path)"), relativePath: path,
                    version: WorkspaceFileVersion(
                        byteCount: 1, modificationDate: nil, contentFingerprint: 0),
                    matches: Array(repeating: match, count: matches), isTruncated: false)
            ],
            totalMatchCount: matches, isTruncated: truncated, statistics: statistics)
    }

    @Test("Results are labelled by root and merged in root order")
    func mergeResults() {
        let merged = WorkspaceSearchMerge.merge([
            WorkspaceSearchMerge.labelled(result("a.swift", matches: 2), label: "app"),
            WorkspaceSearchMerge.labelled(result("b.swift", matches: 3), label: "lib"),
        ])
        #expect(merged.groups.map(\.relativePath) == ["app/a.swift", "lib/b.swift"])
        #expect(merged.totalMatchCount == 5)
        #expect(merged.statistics.searchedFiles == 2)
        #expect(!merged.isTruncated)
    }

    @Test("One root keeps its result unchanged; skipped roots mark truncation")
    func singleRootAndSkipped() {
        let single = result("a.swift", matches: 1)
        #expect(
            WorkspaceSearchMerge.merge([WorkspaceSearchMerge.labelled(single, label: nil)])
                == single)
        #expect(WorkspaceSearchMerge.merge([single], skippedRoots: true).isTruncated)
    }

    @Test("Extra roots survive restoration; older payloads have none")
    func restorationRoundTrip() throws {
        let workspace = RestorableWorkspace(
            bookmark: Data([1]), rootPath: "/work/app", openRelativePaths: [],
            selectedRelativePath: nil, navigatorMode: .files, editorLayout: nil,
            additionalRoots: [.init(bookmark: nil, path: "/work/lib")],
            workspaceFilePath: "/saved/Shop.rafuworkspace")
        let decoded = try JSONDecoder().decode(
            RestorableWorkspace.self, from: JSONEncoder().encode(workspace))
        #expect(decoded.additionalRoots == [.init(bookmark: nil, path: "/work/lib")])
        #expect(decoded.workspaceFilePath == "/saved/Shop.rafuworkspace")

        let older = try JSONEncoder().encode(
            RestorableWorkspace(
                bookmark: Data([1]), rootPath: "/work/app", openRelativePaths: [],
                selectedRelativePath: nil, navigatorMode: .files, editorLayout: nil))
        let text = try #require(String(data: older, encoding: .utf8))
        #expect(!text.contains("additionalRoots"))
        let decodedOlder = try JSONDecoder().decode(RestorableWorkspace.self, from: older)
        #expect(decodedOlder.additionalRoots.isEmpty)
        #expect(decodedOlder.workspaceFilePath == nil)
    }
}

@MainActor
@Suite("Multi-folder workspaces with several repositories")
struct MultiRepositoryWorkspaceTests {
    private func id(_ url: URL) -> String { GitRepositoryRef.identifier(for: url) }

    @Test("Two Git roots are two repositories, in root order")
    func twoRepositoryRoots() async throws {
        let fixture = try MultiRootFixture()
        defer { fixture.remove() }
        let session = fixture.session
        try repositoryFixtureGit(["init", "-q", "-b", "main"], at: fixture.primary)
        try repositoryFixtureGit(["init", "-q", "-b", "dev"], at: fixture.lib)
        session.addFolder(at: fixture.lib)
        session.addFolder(at: fixture.docs)
        await session.reloadGitRepositories()

        #expect(session.gitRepositories.map(\.displayName) == ["app", "lib"])
        #expect(session.gitRepositories.allSatisfy { !$0.isNested })
        #expect(session.sourceControlRootChoices.map(\.name) == ["app", "lib"])
        #expect(session.selectedGitRepository?.id == id(fixture.primary))
    }

    @Test("A child folder with .git is a nested repository; deeper ones are not")
    func nestedRepositoryDiscovered() async throws {
        let fixture = try MultiRootFixture()
        defer { fixture.remove() }
        let session = fixture.session
        try repositoryFixtureGit(["init", "-q"], at: fixture.primary)
        let child = fixture.primary.appending(path: "child", directoryHint: .isDirectory)
        let deep = fixture.primary.appending(path: "a/deep", directoryHint: .isDirectory)
        for folder in [child, deep] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try repositoryFixtureGit(["init", "-q"], at: folder)
        }
        await session.reloadGitRepositories()

        #expect(session.gitRepositories.map(\.displayName) == ["app", "child"])
        let nested = try #require(session.gitRepositories.last)
        #expect(nested.isNested)
        #expect(nested.relativePath == "child")
        #expect(nested.rootID == session.descriptor?.id)

        session.selectGitRepository(nested.id)
        #expect(session.gitRootURL?.standardizedFileURL == child.standardizedFileURL)
        // Badges stay keyed to the primary root's tree.
        #expect(session.effectiveSourceControlRootID == session.descriptor?.id)
        #expect(session.gitBadgeRootURL?.standardizedFileURL == fixture.primary.standardizedFileURL)
    }

    @Test("Selecting the second repository switches the Git root; primary is stored as nil")
    func selectingRepositorySwitchesRoot() async throws {
        let fixture = try MultiRootFixture()
        defer { fixture.remove() }
        let session = fixture.session
        try repositoryFixtureGit(["init", "-q"], at: fixture.primary)
        try repositoryFixtureGit(["init", "-q"], at: fixture.lib)
        session.addFolder(at: fixture.lib)
        await session.reloadGitRepositories()
        let libID = try #require(session.roots.last?.id)

        session.selectGitRepository(id(fixture.lib))
        #expect(session.gitRootURL?.standardizedFileURL == fixture.lib.standardizedFileURL)
        #expect(session.sourceControlRootID == libID)
        #expect(session.effectiveSourceControlRootID == libID)

        session.selectGitRepository(id(fixture.primary))
        #expect(session.sourceControlRepositoryID == nil)
        #expect(session.gitRootURL?.standardizedFileURL == fixture.primary.standardizedFileURL)
    }

    @Test("Summaries are fetched only for listed repositories, not the selected one")
    func summariesOnlyForListedRepositories() async throws {
        let fixture = try MultiRootFixture()
        defer { fixture.remove() }
        let session = fixture.session
        try repositoryFixtureGit(["init", "-q", "-b", "main"], at: fixture.primary)
        try repositoryFixtureGit(["init", "-q", "-b", "dev"], at: fixture.lib)
        try "x\n".write(
            to: fixture.lib.appending(path: "new.txt"), atomically: true, encoding: .utf8)
        session.addFolder(at: fixture.lib)
        await session.reloadGitRepositories()

        session.refreshRepositorySummaries(ids: ["/not/listed", id(fixture.lib)])
        await session.awaitRepositorySummaries()

        #expect(Set(session.gitRepositorySummaries.keys) == [id(fixture.lib)])
        let summary = try #require(session.gitRepositorySummary(for: id(fixture.lib)))
        #expect(summary.branch == "dev")
        // notes.txt (fixture) and new.txt are untracked.
        #expect(summary.changeCount == 2)
    }

    @Test("Hidden section marks changed repositories stale instead of fetching")
    func hiddenSectionDefersSummaries() async throws {
        let fixture = try MultiRootFixture()
        defer { fixture.remove() }
        let session = fixture.session
        try repositoryFixtureGit(["init", "-q"], at: fixture.primary)
        try repositoryFixtureGit(["init", "-q"], at: fixture.lib)
        session.addFolder(at: fixture.lib)
        await session.reloadGitRepositories()

        session.noteRepositorySummariesChanged([id(fixture.lib)])
        #expect(session.repositorySummaryTask == nil)
        #expect(session.staleRepositorySummaryIDs == [id(fixture.lib)])

        session.repositoriesSectionDidAppear()
        await session.awaitRepositorySummaries()
        #expect(session.gitRepositorySummary(for: id(fixture.lib)) != nil)
        #expect(session.staleRepositorySummaryIDs.isEmpty)
        session.repositoriesSectionDidDisappear()
    }

    @Test("Removing a root drops its repository and summary at once")
    func removingRootDropsRepository() async throws {
        let fixture = try MultiRootFixture()
        defer { fixture.remove() }
        let session = fixture.session
        try repositoryFixtureGit(["init", "-q"], at: fixture.primary)
        try repositoryFixtureGit(["init", "-q"], at: fixture.lib)
        session.addFolder(at: fixture.lib)
        await session.reloadGitRepositories()
        session.refreshRepositorySummaries(ids: [id(fixture.lib)])
        await session.awaitRepositorySummaries()
        session.selectGitRepository(id(fixture.lib))
        let libID = try #require(session.roots.last?.id)

        session.removeFolder(libID)
        #expect(session.gitRepositories.map(\.displayName) == ["app"])
        #expect(session.gitRepositorySummary(for: id(fixture.lib)) == nil)
        #expect(session.sourceControlRepositoryID == nil)
    }

    @Test("With a primary root that is not a repository, the first repository is shown")
    func firstRepositoryWhenPrimaryIsNotOne() async throws {
        let fixture = try MultiRootFixture()
        defer { fixture.remove() }
        let session = fixture.session
        try repositoryFixtureGit(["init", "-q"], at: fixture.lib)
        session.addFolder(at: fixture.lib)
        await session.reloadGitRepositories()
        #expect(session.sourceControlRepositoryID == id(fixture.lib))
        #expect(session.gitRootURL?.standardizedFileURL == fixture.lib.standardizedFileURL)
    }

    @Test("Opening the workspace names the branch with one status run and no full refresh")
    func primarySummaryOnOpenWithoutSourceControl() async throws {
        let fixture = try MultiRootFixture()
        defer { fixture.remove() }
        let session = fixture.session
        try repositoryFixtureGit(["init", "-q", "-b", "main"], at: fixture.primary)
        session.navigatorMode = .files
        await session.reloadGitRepositories()
        // The Git step of opening a workspace (`openLocalWorkspace` and
        // restoration both run it).
        await session.refreshWorkspace()

        #expect(session.sourceControlBranchSummary?.branch == "main")
        #expect(session.gitRepositorySummary(for: id(fixture.primary))?.branch == "main")
        // No second summary fetch, no branch list, no history.
        #expect(session.repositorySummaryTask == nil)
        #expect(session.pendingRepositorySummaryIDs.isEmpty)
        #expect(session.gitBranchSnapshot == nil)
        #expect(session.gitHistoryPage == nil)
        #expect(!session.isRepositoriesSectionVisible)
    }

    @Test("The repository of a path is the longest matching folder")
    func longestPrefixLookup() {
        let rootID = UUID()
        let outer = GitRepositoryRef(
            rootID: rootID, url: URL(filePath: "/w/app"), displayName: "app")
        let inner = GitRepositoryRef(
            rootID: rootID, url: URL(filePath: "/w/app/child"), displayName: "child",
            relativePath: "child")
        let repositories = [outer, inner]
        #expect(
            WorkspaceGitRepositories.repository(containing: "/w/app/child/a.c", in: repositories)
                == inner)
        #expect(
            WorkspaceGitRepositories.repository(containing: "/w/app/childish/a", in: repositories)
                == outer)
        #expect(
            WorkspaceGitRepositories.repository(containing: "/w/other/a", in: repositories) == nil)
    }

    @Test("A change batch touches the repositories whose folders changed")
    func changeImpact() {
        let rootID = UUID()
        let outer = GitRepositoryRef(
            rootID: rootID, url: URL(filePath: "/w/app"), displayName: "app")
        let inner = GitRepositoryRef(
            rootID: rootID, url: URL(filePath: "/w/app/child"), displayName: "child",
            relativePath: "child")
        let repositories = [outer, inner]

        let edit = WorkspaceGitRepositories.impact(
            of: WorkspaceChangeSet(treeChanged: true, changedDirectoryRelativePaths: ["child/src"]),
            repositories: repositories)
        #expect(edit.state.isEmpty)
        #expect(edit.tree == [outer.id, inner.id])

        let commit = WorkspaceGitRepositories.impact(
            of: WorkspaceChangeSet(nestedGitChangedDirectories: ["child"]),
            repositories: repositories)
        #expect(commit.state == [inner.id])
        #expect(commit.tree.isEmpty)

        let outerOnly = WorkspaceGitRepositories.impact(
            of: WorkspaceChangeSet(
                treeChanged: true, gitChanged: true, changedDirectoryRelativePaths: ["src"]),
            repositories: repositories)
        #expect(outerOnly.state == [outer.id])
        #expect(outerOnly.tree.isEmpty)

        let ignored = WorkspaceGitRepositories.impact(
            of: WorkspaceChangeSet(ignoredDirectoryRelativePaths: [".venv"]),
            repositories: repositories)
        #expect(ignored.state.isEmpty && ignored.tree.isEmpty)
    }

    @Test("Row text names branch and counts in words")
    func rowPresentation() {
        let repository = GitRepositoryRef(
            rootID: UUID(), url: URL(filePath: "/w/app"), displayName: "app")
        let loading = GitRepositoryRowPresentation(repository: repository, summary: nil)
        #expect(loading.accessibilityValue == "Loading status")
        #expect(loading.changeText == nil)

        let busy = GitRepositoryRowPresentation(
            repository: repository,
            summary: GitRepositorySummary(
                branch: "main", aheadCount: 2, behindCount: 1, changeCount: 3, conflictCount: 1))
        #expect(busy.branchText == "main")
        #expect(busy.changeText == "3")
        #expect(busy.conflictText == "1")
        #expect(
            busy.accessibilityValue
                == "Branch main, 3 changes, 1 conflict, 2 ahead, 1 behind")

        let detached = GitRepositoryRowPresentation(
            repository: repository,
            summary: GitRepositorySummary(branch: "HEAD", isDetached: true))
        #expect(detached.branchText == "detached")
        #expect(detached.accessibilityValue == "Detached HEAD, No changes")
    }
}

private func repositoryFixtureGit(_ arguments: [String], at root: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw RepositoryFixtureError.gitFailed(arguments)
    }
}

private enum RepositoryFixtureError: Error {
    case gitFailed([String])
}

@MainActor
private struct MultiRootFixture {
    let session: WorkspaceSession
    let base: URL
    let primary: URL
    let lib: URL
    let docs: URL
    private let suite: String

    init() throws {
        suite = "dev.rafu.multi-root.\(UUID().uuidString)"
        base = FileManager.default.temporaryDirectory.appending(
            path: "rafu-multi-root-\(UUID().uuidString)", directoryHint: .isDirectory)
        primary = base.appending(path: "app", directoryHint: .isDirectory)
        lib = base.appending(path: "lib", directoryHint: .isDirectory)
        docs = base.appending(path: "docs", directoryHint: .isDirectory)
        for folder in [primary, lib, docs] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try "notes\n".write(to: lib.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        session = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(defaultsSuiteName: suite))
        // Lightweight pattern (see WorkspaceDiffHoverTests): set the
        // descriptor instead of the full open path.
        session.descriptor = WorkspaceDescriptor(
            displayName: "app", location: .local(LocalWorkspaceReference(path: primary.path)))
    }

    func remove() {
        session.tearDownAdditionalRoots()
        session.descriptor = nil
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: base)
    }
}
