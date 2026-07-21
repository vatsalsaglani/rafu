import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// Data-level proof for `WorkspaceSession.diffHoverInfo(path:line:
/// utf16Column:)` (diff-syntax-highlighting-and-hover phase, Part B4):
/// every required gate independently yields `nil`. Fixtures follow
/// `WorkspaceGotoLocationTests`' lightweight pattern — set `descriptor`
/// directly rather than calling `openLocalWorkspace(at:)`, which also spins
/// up a liveness file watcher with no cheap teardown seam for tests. That
/// choice means `navigationLadder` stays `nil` in every fixture here, which
/// is itself one of `diffHoverInfo`'s required gates — see
/// `ladderNeverAnsweredWhenEveryOtherGatePasses` for why that is still
/// meaningful coverage, and its doc comment for the honest limitation this
/// leaves (per the phase brief's own fallback: "if none exists cheaply,
/// assert the nil result only and note it" — `NavigationLadder` has no
/// spy/injection seam in this codebase).
@MainActor
@Suite("WorkspaceSession diff hover gating")
struct WorkspaceDiffHoverTests {
    @Test("diffHoverInfo is nil when there is no open diff")
    func nilWithNoOpenDiff() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        #expect(session.gitOpenDiff == nil)

        let info = await session.diffHoverInfo(
            path: fixture.relativePath, line: 1, utf16Column: 0)
        #expect(info == nil)
    }

    @Test("diffHoverInfo is nil when the open diff's path doesn't match the request")
    func nilWithPathMismatch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        session.gitOpenDiff = fixture.openDiff(path: fixture.relativePath, scope: .workingTree)

        let info = await session.diffHoverInfo(
            path: "some/other/path.swift", line: 1, utf16Column: 0)
        #expect(info == nil)
    }

    @Test("diffHoverInfo is nil for a history/commit-scoped diff")
    func nilWithHistoryScope() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        session.gitOpenDiff = fixture.openDiff(
            path: fixture.relativePath, scope: .commit("deadbeef"))

        let info = await session.diffHoverInfo(
            path: fixture.relativePath, line: 1, utf16Column: 0)
        #expect(info == nil)
    }

    @Test("diffHoverInfo is nil when the matching open document is dirty")
    func nilWithDirtyOpenDocument() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        session.gitOpenDiff = fixture.openDiff(path: fixture.relativePath, scope: .workingTree)
        let document = EditorDocument(url: fixture.fileURL)
        document.isDirty = true
        document.textSnapshotProvider = { "let value = 1\n" }
        session.openDocuments = [document]

        let info = await session.diffHoverInfo(
            path: fixture.relativePath, line: 1, utf16Column: 4)
        #expect(info == nil)
    }

    /// The last-line-of-defense proxy for "gating never fires the
    /// navigation ladder" (item 14): every OTHER required condition is
    /// satisfied here — a real on-disk file, a matching working-tree
    /// `gitOpenDiff`, no dirty open document, and a resolvable
    /// `(line, utf16Column)` — yet the result is still `nil` because this
    /// fixture never wires a `navigationLadder`
    /// (`WorkspaceGotoLocationTests`' lightweight pattern; see the suite
    /// doc). `NavigationLadder` has no spy/injection seam to assert
    /// "resolve was never called" more directly, so this test asserts the
    /// nil result only, per the phase brief's documented fallback.
    @Test(
        "diffHoverInfo never answers without a navigation ladder, even when every other gate passes"
    )
    func ladderNeverAnsweredWhenEveryOtherGatePasses() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        session.gitOpenDiff = fixture.openDiff(path: fixture.relativePath, scope: .workingTree)
        #expect(session.rootURL != nil)

        let info = await session.diffHoverInfo(
            path: fixture.relativePath, line: 1, utf16Column: 4)
        #expect(info == nil)
    }
}

private struct Fixture {
    let rootURL: URL
    let fileURL: URL
    let relativePath = "Sources/main.swift"

    init(diskText: String = "let value = 1\n") throws {
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "rafu-diff-hover-\(UUID().uuidString)", directoryHint: .isDirectory)
        fileURL = rootURL.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try diskText.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    @MainActor
    func session() -> WorkspaceSession {
        let session = WorkspaceSession()
        session.descriptor = WorkspaceDescriptor(
            displayName: rootURL.lastPathComponent,
            location: .local(LocalWorkspaceReference(path: rootURL.path))
        )
        return session
    }

    @MainActor
    func openDiff(path: String, scope: GitDiffScope) -> GitOpenDiff {
        GitOpenDiff(
            title: path,
            subtitle: "",
            diff: GitFileDiff(
                path: path,
                originalPath: nil,
                isBinary: false,
                hunks: [
                    GitDiffHunk(
                        id: 0,
                        header: "@@ -1,1 +1,1 @@",
                        oldStart: 1,
                        oldCount: 1,
                        newStart: 1,
                        newCount: 1,
                        rows: [
                            GitDiffRow(
                                id: 0,
                                oldLine: GitDiffLine(number: 1, content: "old", kind: .context),
                                newLine: GitDiffLine(
                                    number: 1, content: "let value = 1", kind: .context),
                                kind: .context
                            )
                        ]
                    )
                ],
                rawPatch: ""
            ),
            identity: "diff-\(path)",
            scope: scope
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
