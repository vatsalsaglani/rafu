import Foundation
import Testing

@testable import RafuApp

@Suite("Git service")
struct GitServiceTests {
    @Test("Unborn repositories support grouped status, diff, stage, commit, history, and branches")
    func unbornRepositoryLifecycle() async throws {
        try await withRepository { root in
            try write("# Rafu\nsecond line\n", to: root.appending(path: "README.md"))
            try FileManager.default.createDirectory(
                at: root.appending(path: "folder"), withIntermediateDirectories: true)
            try write("value\n", to: root.appending(path: "folder/name with space.txt"))

            let service = GitService()
            let initial = try #require(try await service.snapshot(at: root))
            #expect(initial.branch == "main")
            #expect(initial.isUnborn)
            #expect(initial.stagedChanges.isEmpty)
            #expect(
                Set(initial.unstagedChanges.map(\.path))
                    == Set(["README.md", "folder/name with space.txt"])
            )

            let untrackedDiff = try await service.diff(
                GitDiffRequest(path: "README.md"),
                at: root
            )
            #expect(!untrackedDiff.isBinary)
            #expect(untrackedDiff.rows.count == 2)
            #expect(untrackedDiff.rows.allSatisfy { $0.kind == .addition })

            try await service.setStaged(true, path: "README.md", at: root)
            let staged = try #require(try await service.snapshot(at: root))
            #expect(staged.stagedChanges.map(\.path) == ["README.md"])
            #expect(staged.unstagedChanges.map(\.path) == ["folder/name with space.txt"])

            let stagedDiff = try await service.diff(
                GitDiffRequest(path: "README.md", scope: .staged),
                at: root
            )
            #expect(stagedDiff.rows.count == 2)

            try await service.setStaged(false, path: "README.md", at: root)
            #expect(try #require(try await service.snapshot(at: root)).stagedChanges.isEmpty)

            try await service.stageAll(at: root)
            _ = try await service.commit(message: "Initial commit from Rafu", at: root)

            let committed = try #require(try await service.snapshot(at: root))
            #expect(!committed.isUnborn)
            #expect(committed.changes.isEmpty)

            let history = try await service.history(at: root, limit: 20)
            #expect(history.commits.count == 1)
            #expect(history.commits.first?.subject == "Initial commit from Rafu")
            let commit = try #require(history.commits.first)
            let commitChanges = try await service.commitChanges(commit.id, at: root)
            #expect(
                Set(commitChanges.map(\.path))
                    == Set(["README.md", "folder/name with space.txt"])
            )
            let historicalDiff = try await service.diff(
                GitDiffRequest(path: "README.md", scope: .commit(commit.id)),
                at: root
            )
            #expect(historicalDiff.rows.count == 2)

            let branches = try #require(try await service.branches(at: root))
            #expect(branches.currentBranch == "main")
            #expect(branches.localBranches.map(\.name) == ["main"])
        }
    }

    @Test("Working and staged diffs align replacement rows side by side")
    func sideBySideDiff() async throws {
        try await withRepository { root in
            let file = root.appending(path: "sample.txt")
            try write("alpha\nbeta\nomega\n", to: file)
            try runGit(["add", "sample.txt"], at: root)
            try runGit(["commit", "-m", "Base"], at: root)
            try write("alpha\nchanged\ninserted\nomega\n", to: file)

            let service = GitService()
            let working = try await service.diff(GitDiffRequest(path: "sample.txt"), at: root)
            #expect(
                working.rows.contains { row in
                    row.kind == .modification
                        && row.oldLine?.content == "beta"
                        && row.newLine?.content == "changed"
                })
            #expect(
                working.rows.contains { $0.kind == .addition && $0.newLine?.content == "inserted" })

            try await service.setStaged(true, path: "sample.txt", at: root)
            let staged = try await service.diff(
                GitDiffRequest(path: "sample.txt", scope: .staged), at: root)
            #expect(staged.rows == working.rows)
        }
    }

    @Test("Conflict status is separated from staged and unstaged groups")
    func conflictGrouping() async throws {
        try await withRepository { root in
            let file = root.appending(path: "conflict.txt")
            try write("base\n", to: file)
            try runGit(["add", "conflict.txt"], at: root)
            try runGit(["commit", "-m", "Base"], at: root)
            try runGit(["checkout", "-b", "feature"], at: root)
            try write("feature\n", to: file)
            try runGit(["commit", "-am", "Feature"], at: root)
            try runGit(["checkout", "main"], at: root)
            try write("main\n", to: file)
            try runGit(["commit", "-am", "Main"], at: root)

            let service = GitService()
            await #expect(throws: GitServiceError.self) {
                _ = try await service.merge(branch: "feature", at: root)
            }
            let snapshot = try #require(try await service.snapshot(at: root))
            #expect(snapshot.conflicts.map(\.path) == ["conflict.txt"])
            #expect(snapshot.stagedChanges.isEmpty)
            #expect(snapshot.unstagedChanges.isEmpty)
            let conflictDiff = try await service.diff(
                GitDiffRequest(path: "conflict.txt"), at: root)
            #expect(!conflictDiff.hunks.isEmpty)
            #expect(
                conflictDiff.rows.contains {
                    $0.kind == .addition && $0.newLine?.content == "<<<<<<< HEAD"
                })
        }
    }

    @Test("Branch creation, checkout, and fast-forward merge are supported")
    func branchOperations() async throws {
        try await withRepository { root in
            try write("base\n", to: root.appending(path: "file.txt"))
            try runGit(["add", "file.txt"], at: root)
            try runGit(["commit", "-m", "Base"], at: root)

            let service = GitService()
            try await service.createBranch(named: "feature/work", at: root)
            try write("feature\n", to: root.appending(path: "feature.txt"))
            try await service.stageAll(at: root)
            _ = try await service.commit(message: "Feature", at: root)
            try await service.checkout(branch: "main", at: root)
            _ = try await service.merge(
                branch: "feature/work", strategy: .fastForwardOnly, at: root)

            let branches = try #require(try await service.branches(at: root))
            #expect(branches.currentBranch == "main")
            #expect(Set(branches.localBranches.map(\.name)) == ["main", "feature/work"])
            #expect(
                FileManager.default.fileExists(atPath: root.appending(path: "feature.txt").path))
        }
    }

    @Test("Merge state is detected while a merge is in progress and clears after")
    func mergeStateDetection() async throws {
        try await withRepository { root in
            try write("base\n", to: root.appending(path: "file.txt"))
            try runGit(["add", "file.txt"], at: root)
            try runGit(["commit", "-m", "Base"], at: root)
            try runGit(["checkout", "-b", "side"], at: root)
            try write("side\n", to: root.appending(path: "side.txt"))
            try runGit(["add", "side.txt"], at: root)
            try runGit(["commit", "-m", "Side"], at: root)
            try runGit(["checkout", "main"], at: root)
            try write("main\n", to: root.appending(path: "main.txt"))
            try runGit(["add", "main.txt"], at: root)
            try runGit(["commit", "-m", "Main"], at: root)

            let service = GitService()
            #expect(try await service.mergeState(at: root) == nil)

            try runGit(["merge", "side", "--no-commit", "--no-ff"], at: root)
            let state = try #require(try await service.mergeState(at: root))
            #expect(state.headline.hasPrefix("Merge"))
            #expect(state.defaultMessage.hasPrefix("Merge"))
            #expect(!state.defaultMessage.contains("#"))

            _ = try await service.commit(message: state.defaultMessage, at: root)
            #expect(try await service.mergeState(at: root) == nil)
        }
    }

    @Test("Fetch, pull, push, upstream, and ahead/behind state work with a local remote")
    func remoteOperations() async throws {
        let sandbox = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let origin = sandbox.appending(path: "origin.git", directoryHint: .isDirectory)
        let local = sandbox.appending(path: "local", directoryHint: .isDirectory)
        let peer = sandbox.appending(path: "peer", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try runGit(["init", "--bare", "-b", "main"], at: origin)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try initializeRepository(at: local)
        try runGit(["remote", "add", "origin", origin.path], at: local)
        try write("base\n", to: local.appending(path: "shared.txt"))
        try runGit(["add", "shared.txt"], at: local)
        try runGit(["commit", "-m", "Base"], at: local)

        let service = GitService()
        _ = try await service.push(
            GitPushRequest(remote: "origin", branch: "main", setUpstream: true), at: local)
        let tracking = try #require(try await service.branches(at: local))
        #expect(tracking.upstream == "origin/main")
        #expect(tracking.aheadCount == 0)
        #expect(tracking.behindCount == 0)

        try runGit(["clone", origin.path, peer.path], at: sandbox)
        try configureIdentity(at: peer)
        try write("from peer\n", to: peer.appending(path: "peer.txt"))
        try runGit(["add", "peer.txt"], at: peer)
        try runGit(["commit", "-m", "Peer"], at: peer)
        try runGit(["push"], at: peer)

        _ = try await service.fetch(GitFetchRequest(remote: "origin"), at: local)
        let behind = try #require(try await service.branches(at: local))
        #expect(behind.behindCount == 1)
        _ = try await service.pull(GitPullRequest(strategy: .fastForwardOnly), at: local)
        #expect(FileManager.default.fileExists(atPath: local.appending(path: "peer.txt").path))

        try write("local\n", to: local.appending(path: "local.txt"))
        try await service.stageAll(at: local)
        _ = try await service.commit(message: "Local", at: local)
        _ = try await service.push(at: local)
        #expect(try #require(try await service.branches(at: local)).aheadCount == 0)
    }

    @Test("Command capture handles output larger than a pipe buffer")
    func largeOutputCapture() async throws {
        try await withRepository { root in
            let left = String(repeating: "left line\n", count: 20_000)
            let right = String(repeating: "right line\n", count: 20_000)
            try write(left, to: root.appending(path: "left.txt"))
            try write(right, to: root.appending(path: "right.txt"))

            let output = try await GitCommandRunner().run(
                arguments: ["diff", "--no-index", "--", "left.txt", "right.txt"],
                at: root
            )
            #expect(output.terminationStatus == 1)
            #expect(output.standardOutput.count > 64 * 1_024)
        }
    }

    @Test("Batch staging handles 100+ paths, spaces, and pathspec-magic names in one process")
    func batchStagingHandlesManyAndUnusualPaths() async throws {
        try await withRepository { root in
            try FileManager.default.createDirectory(
                at: root.appending(path: "many"), withIntermediateDirectories: true)
            var expectedPaths: [String] = []
            for index in 0..<120 {
                let path = "many/file-\(index).txt"
                try write("value \(index)\n", to: root.appending(path: path))
                expectedPaths.append(path)
            }
            let magicPath = "[a].txt"
            let spacedPath = "folder/name with space.txt"
            try write("glob-magic\n", to: root.appending(path: magicPath))
            try FileManager.default.createDirectory(
                at: root.appending(path: "folder"), withIntermediateDirectories: true)
            try write("spaced\n", to: root.appending(path: spacedPath))
            expectedPaths.append(contentsOf: [magicPath, spacedPath])

            let service = GitService()
            try await service.setStaged(true, paths: expectedPaths, at: root)

            let staged = try #require(try await service.snapshot(at: root))
            #expect(Set(staged.stagedChanges.map(\.path)) == Set(expectedPaths))
            #expect(staged.unstagedChanges.isEmpty)

            try await service.setStaged(false, paths: expectedPaths, at: root)
            let unstaged = try #require(try await service.snapshot(at: root))
            #expect(unstaged.stagedChanges.isEmpty)
            #expect(Set(unstaged.unstagedChanges.map(\.path)) == Set(expectedPaths))
        }
    }

    @Test("Batch unstage in an unborn repository removes files from the index, not the worktree")
    func batchUnstageWorksBeforeFirstCommit() async throws {
        try await withRepository { root in
            let paths = ["a.txt", "b.txt", "[c].txt"]
            for path in paths {
                try write("value\n", to: root.appending(path: path))
            }
            let service = GitService()
            try await service.setStaged(true, paths: paths, at: root)
            #expect(try #require(try await service.snapshot(at: root)).stagedChanges.count == 3)

            try await service.setStaged(false, paths: paths, at: root)
            let snapshot = try #require(try await service.snapshot(at: root))
            #expect(snapshot.stagedChanges.isEmpty)
            #expect(Set(snapshot.unstagedChanges.map(\.path)) == Set(paths))
            for path in paths {
                #expect(FileManager.default.fileExists(atPath: root.appending(path: path).path))
            }
        }
    }

    @Test("Line stats merge working-tree and staged numstat, keyed by path")
    func changeLineStatsMergesWorkingAndStaged() async throws {
        try await withRepository { root in
            let file = root.appending(path: "sample.txt")
            try write("a\nb\nc\n", to: file)
            try runGit(["add", "sample.txt"], at: root)
            try runGit(["commit", "-m", "Base"], at: root)

            // Stage one line of change, then add another unstaged line.
            try write("a\nb\nc\nd\n", to: file)
            let service = GitService()
            try await service.setStaged(true, path: "sample.txt", at: root)
            try write("a\nb\nc\nd\ne\n", to: file)

            let stats = try await service.changeLineStats(at: root)
            let merged = try #require(stats["sample.txt"])
            #expect(merged.added == 2)
            #expect(merged.deleted == 0)
            #expect(!merged.isBinary)
        }
    }

    @Test("Overlapping partially staged hunk round-trips without staging a distant hunk")
    func overlappingPartiallyStagedHunkRoundTrip() async throws {
        try await withRepository { root in
            let file = root.appending(path: "partial.txt")
            let baseLines = (1...24).map { "line \($0)" }
            try write(baseLines.joined(separator: "\n") + "\n", to: file)
            try runGit(["add", "partial.txt"], at: root)
            try runGit(["commit", "-m", "Base"], at: root)

            var stagedLines = baseLines
            stagedLines[3] = "line 4 staged"
            try write(stagedLines.joined(separator: "\n") + "\n", to: file)
            try runGit(["add", "partial.txt"], at: root)

            var workingLines = stagedLines
            workingLines[3] = "line 4 final"
            workingLines[19] = "line 20 working"
            try write(workingLines.joined(separator: "\n") + "\n", to: file)

            let service = GitService()
            let working = try await service.diff(GitDiffRequest(path: "partial.txt"), at: root)
            #expect(working.hunks.count == 2)
            let overlappingHunk = try #require(working.hunks.first)
            let stagePatch = try GitHunkPatchBuilder.patch(for: overlappingHunk, in: working)
            #expect(stagePatch.contains("-line 4 staged\n+line 4 final"))
            #expect(!stagePatch.contains("line 20 working"))

            try await service.applyHunk(patch: stagePatch, staging: true, at: root)

            let staged = try await service.diff(
                GitDiffRequest(path: "partial.txt", scope: .staged), at: root)
            let remainingWorking = try await service.diff(
                GitDiffRequest(path: "partial.txt"), at: root)
            #expect(staged.rawPatch.contains("+line 4 final"))
            #expect(!staged.rawPatch.contains("line 4 staged"))
            #expect(!staged.rawPatch.contains("line 20 working"))
            #expect(!remainingWorking.rawPatch.contains("line 4 final"))
            #expect(remainingWorking.rawPatch.contains("+line 20 working"))

            let unstageHunk = try #require(staged.hunks.first)
            let unstagePatch = try GitHunkPatchBuilder.patch(for: unstageHunk, in: staged)
            try await service.applyHunk(patch: unstagePatch, staging: false, at: root)

            let cleanIndex = try await service.diff(
                GitDiffRequest(path: "partial.txt", scope: .staged), at: root)
            let restoredWorking = try await service.diff(
                GitDiffRequest(path: "partial.txt"), at: root)
            #expect(cleanIndex.rawPatch.isEmpty)
            #expect(restoredWorking.rawPatch.contains("+line 4 final"))
            #expect(restoredWorking.rawPatch.contains("+line 20 working"))
        }
    }
}

private func withRepository(
    _ body: (URL) async throws -> Void
) async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try initializeRepository(at: root)
    try await body(root)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "rafu-git-tests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func initializeRepository(at root: URL) throws {
    try runGit(["init", "-b", "main"], at: root)
    try configureIdentity(at: root)
}

private func configureIdentity(at root: URL) throws {
    try runGit(["config", "user.name", "Rafu Tests"], at: root)
    try runGit(["config", "user.email", "rafu-tests@example.invalid"], at: root)
}

private func write(_ value: String, to url: URL) throws {
    try Data(value.utf8).write(to: url)
}

private func runGit(_ arguments: [String], at root: URL) throws {
    let process = Process()
    let capture = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    _ = FileManager.default.createFile(atPath: capture.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: capture) }
    let error = try FileHandle(forWritingTo: capture)
    defer { try? error.close() }
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = error
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_EDITOR"] = "true"
    process.environment = environment
    try process.run()
    process.waitUntilExit()
    try error.close()
    guard process.terminationStatus == 0 else {
        throw GitTestError.commandFailed(
            String(decoding: try Data(contentsOf: capture), as: UTF8.self)
        )
    }
}

private enum GitTestError: Error {
    case commandFailed(String)
}
