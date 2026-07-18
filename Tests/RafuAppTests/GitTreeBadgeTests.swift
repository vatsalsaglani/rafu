import Foundation
import Testing

@testable import RafuApp

@Suite("Git file-tree badges")
struct GitTreeBadgeTests {
    private func change(
        _ path: String, index: Character, worktree: Character, original: String? = nil
    ) -> GitChange {
        GitChange(
            path: path, originalPath: original, indexStatus: index, worktreeStatus: worktree)
    }

    private func snapshot(_ changes: [GitChange], root: URL) -> GitSnapshot {
        GitSnapshot(repositoryRoot: root, branch: "main", changes: changes)
    }

    @Test("File badges carry the exact git short code")
    func fileBadgesUseShortCodes() {
        let root = URL(filePath: "/repo")
        let snap = snapshot(
            [
                change(".env", index: ".", worktree: "M"),
                change("compose.yaml", index: "?", worktree: "?"),
                change("Dockerfile", index: "M", worktree: "."),
            ], root: root)
        let badges = snap.treeBadges(workspaceRoot: root)

        #expect(badges[".env"]?.shortCode == "M")
        #expect(badges[".env"]?.isDirectory == false)
        #expect(badges["compose.yaml"]?.shortCode == "??")
        #expect(badges["compose.yaml"]?.kind == .untracked)
        #expect(badges["Dockerfile"]?.shortCode == "M")
        #expect(badges["README.md"] == nil)
    }

    @Test("A nested change decorates every ancestor directory up to the root")
    func ancestorsCarryTheStatus() {
        let root = URL(filePath: "/repo")
        let snap = snapshot(
            [change("Sources/App/Model.swift", index: ".", worktree: "M")], root: root)
        let badges = snap.treeBadges(workspaceRoot: root)

        #expect(badges["Sources/App/Model.swift"]?.isDirectory == false)
        #expect(badges["Sources"]?.isDirectory == true)
        #expect(badges["Sources"]?.kind == .modified)
        #expect(badges["Sources/App"]?.kind == .modified)
        // The workspace root itself is never a row and is not decorated.
        #expect(badges[""] == nil)
    }

    @Test("A directory aggregates the most severe descendant status")
    func directoryAggregatesBySeverity() {
        let root = URL(filePath: "/repo")
        let snap = snapshot(
            [
                change("Sources/new.swift", index: "?", worktree: "?"),
                change("Sources/edited.swift", index: ".", worktree: "M"),
            ], root: root)
        let badges = snap.treeBadges(workspaceRoot: root)

        // Modified outranks untracked, so the folder shows the modified color.
        #expect(badges["Sources"]?.kind == .modified)
        #expect(badges["Sources"]?.shortCode == "M")
        // Files keep their own exact status.
        #expect(badges["Sources/new.swift"]?.shortCode == "??")
        #expect(badges["Sources/edited.swift"]?.shortCode == "M")
    }

    @Test("Conflicts win the folder aggregate over modifications")
    func conflictsDominateAggregate() {
        let root = URL(filePath: "/repo")
        let snap = snapshot(
            [
                change("pkg/a.swift", index: ".", worktree: "M"),
                change("pkg/b.swift", index: "U", worktree: "U"),
            ], root: root)
        let badges = snap.treeBadges(workspaceRoot: root)

        #expect(badges["pkg"]?.kind == .conflicted)
        #expect(badges["pkg"]?.shortCode == "U")
    }

    @Test("Changes outside the open workspace subtree are ignored")
    func changesAboveWorkspaceRootAreDropped() {
        // Repo root is an ancestor of the opened workspace folder.
        let repoRoot = URL(filePath: "/repo")
        let workspace = URL(filePath: "/repo/app")
        let snap = snapshot(
            [
                change("app/main.swift", index: ".", worktree: "M"),
                change("tooling/build.sh", index: ".", worktree: "M"),
            ], root: repoRoot)
        let badges = snap.treeBadges(workspaceRoot: workspace)

        // Re-expressed relative to the workspace; the sibling folder is gone.
        #expect(badges["main.swift"]?.shortCode == "M")
        #expect(badges["tooling"] == nil)
        #expect(badges["tooling/build.sh"] == nil)
    }

    @Test("No repository or no changes yields no badges")
    func emptyWhenNothingChanged() {
        let root = URL(filePath: "/repo")
        #expect(snapshot([], root: root).treeBadges(workspaceRoot: root).isEmpty)
    }
}
