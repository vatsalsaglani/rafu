import Foundation
import Testing

@testable import RafuCore

@Suite("Workspace roots")
struct WorkspaceRootListTests {
    @Test("Paths are standardized without a trailing slash")
    func normalizesPaths() {
        #expect(WorkspaceRootList.normalizedPath("/a/b/") == "/a/b")
        #expect(WorkspaceRootList.normalizedPath("/a/./b/../c") == "/a/c")
        #expect(WorkspaceRootList.normalizedPath("/") == "/")
        #expect(WorkspaceRoot(path: "/x/y/").path == "/x/y")
    }

    @Test("Adding keeps order, refuses duplicates, and stops at the limit")
    func addingRoots() throws {
        let primary = WorkspaceRoot(path: "/work/app")
        guard case .added(let two) = WorkspaceRootList.adding(path: "/work/lib", to: [primary])
        else {
            Issue.record("Expected the folder to be added")
            return
        }
        #expect(two.map(\.path) == ["/work/app", "/work/lib"])
        #expect(two.first?.id == primary.id)
        #expect(
            WorkspaceRootList.adding(path: "/work/lib/", to: two) == .duplicate(two[1].id))
        #expect(WorkspaceRootList.adding(path: "relative/path", to: two) == .invalidPath)

        let full = (0..<WorkspaceRootList.maximumRoots).map { WorkspaceRoot(path: "/r/\($0)") }
        #expect(WorkspaceRootList.adding(path: "/r/extra", to: full) == .limitReached)
    }

    @Test("The primary root is never removed")
    func removingRoots() {
        let roots = [
            WorkspaceRoot(path: "/a"), WorkspaceRoot(path: "/b"), WorkspaceRoot(path: "/c"),
        ]
        #expect(WorkspaceRootList.removing(id: roots[0].id, from: roots) == roots)
        #expect(
            WorkspaceRootList.removing(id: roots[1].id, from: roots).map(\.path) == ["/a", "/c"])
        #expect(WorkspaceRootList.removing(id: UUID(), from: roots) == roots)
    }

    @Test("A primary index moves that item first and keeps the rest in order")
    func reordering() {
        #expect(WorkspaceRootList.reordered([1, 2, 3, 4], primaryIndex: 2) == [3, 1, 2, 4])
        #expect(WorkspaceRootList.reordered([1, 2, 3], primaryIndex: nil) == [1, 2, 3])
        #expect(WorkspaceRootList.reordered([1, 2, 3], primaryIndex: 9) == [1, 2, 3])
        #expect(WorkspaceRootList.reordered([1, 2, 3], primaryIndex: 0) == [1, 2, 3])
    }

    @Test("Display names add the parent folder only when names collide")
    func displayNames() {
        let app = WorkspaceRoot(path: "/work/client/app")
        let other = WorkspaceRoot(path: "/work/server/app")
        let lib = WorkspaceRoot(path: "/work/lib")
        let names = WorkspaceRootList.displayNames(for: [app, other, lib])
        #expect(names[app.id] == "client/app")
        #expect(names[other.id] == "server/app")
        #expect(names[lib.id] == "lib")

        let first = WorkspaceRoot(path: "/one/x/app")
        let second = WorkspaceRoot(path: "/two/x/app")
        let full = WorkspaceRootList.displayNames(for: [first, second])
        #expect(full[first.id] == "/one/x/app")
        #expect(full[second.id] == "/two/x/app")
    }

    @Test("Paths are shown with a root prefix only in a multi-root workspace")
    func displayPaths() {
        let app = WorkspaceRoot(path: "/work/app")
        let lib = WorkspaceRoot(path: "/work/lib")
        #expect(
            WorkspaceRootList.displayPath(relativePath: "a.swift", rootID: app.id, roots: [app])
                == "a.swift")
        #expect(
            WorkspaceRootList.displayPath(
                relativePath: "Sources/a.swift", rootID: lib.id, roots: [app, lib])
                == "lib/Sources/a.swift")
        #expect(
            WorkspaceRootList.displayPath(relativePath: "", rootID: lib.id, roots: [app, lib])
                == "lib")
    }

    @Test("The deepest containing root wins")
    func locating() throws {
        let outer = WorkspaceRoot(path: "/work")
        let inner = WorkspaceRoot(path: "/work/pkg")
        let found = try #require(
            WorkspaceRootList.locate(absolutePath: "/work/pkg/a/b.txt", in: [outer, inner]))
        #expect(found.root.id == inner.id)
        #expect(found.relativePath == "a/b.txt")
        let top = try #require(
            WorkspaceRootList.locate(absolutePath: "/work/readme.md", in: [outer, inner]))
        #expect(top.root.id == outer.id)
        #expect(top.relativePath == "readme.md")
        #expect(WorkspaceRootList.locate(absolutePath: "/workshop/x", in: [outer]) == nil)
        #expect(WorkspaceRootList.locate(absolutePath: "/work", in: [outer])?.relativePath == "")
    }

    @Test("A root inside a repository is found by walking up to .git")
    func gitDetection() {
        let existing: Set<String> = ["/work/repo/.git"]
        let exists: (String) -> Bool = { existing.contains($0) }
        #expect(WorkspaceRootList.isInsideGitWorkTree(path: "/work/repo", fileExists: exists))
        #expect(
            WorkspaceRootList.isInsideGitWorkTree(path: "/work/repo/pkg/sub", fileExists: exists))
        #expect(!WorkspaceRootList.isInsideGitWorkTree(path: "/work/other", fileExists: exists))
        #expect(!WorkspaceRootList.isInsideGitWorkTree(path: "relative", fileExists: exists))
    }

    @Test("Interleaving is round robin and bounded")
    func interleaving() {
        #expect(
            WorkspaceRootList.interleave([[1, 2, 3], [10, 20], [100]], limit: 10)
                == [1, 10, 100, 2, 20, 3])
        #expect(WorkspaceRootList.interleave([[1, 2, 3], [10, 20]], limit: 3) == [1, 10, 2])
        #expect(WorkspaceRootList.interleave([[Int]](), limit: 5).isEmpty)
        #expect(WorkspaceRootList.interleave([[1]], limit: 0).isEmpty)
    }
}
