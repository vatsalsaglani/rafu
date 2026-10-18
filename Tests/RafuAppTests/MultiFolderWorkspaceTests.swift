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
            WorkspaceFileMatch(rootID: libID, relativePath: "notes.txt", displayPath: "lib/notes.txt"))

        let document = try #require(session.selectedDocument)
        #expect(document.url.standardizedFileURL == fixture.lib.appending(path: "notes.txt").standardizedFileURL)
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
        #expect(WorkspaceSearchMerge.merge([WorkspaceSearchMerge.labelled(single, label: nil)]) == single)
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
