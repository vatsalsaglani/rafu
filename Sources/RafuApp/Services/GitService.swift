import Foundation

nonisolated struct GitService: Sendable {
    private let runner = GitCommandRunner()

    @concurrent
    func snapshot(at rootURL: URL) async throws -> GitSnapshot? {
        guard let repositoryRoot = try await repositoryRoot(at: rootURL) else { return nil }
        let output = try await checkedRun(
            ["status", "--porcelain=v2", "--branch", "--untracked-files=all", "-z"],
            at: repositoryRoot
        )
        let parsed = GitStatusParser.parse(output.standardOutput)
        return GitSnapshot(
            repositoryRoot: repositoryRoot,
            branch: parsed.branch,
            headOID: parsed.headOID,
            upstream: parsed.upstream,
            aheadCount: parsed.aheadCount,
            behindCount: parsed.behindCount,
            isDetached: parsed.isDetached,
            isUnborn: parsed.isUnborn,
            changes: parsed.changes
        )
    }

    @concurrent
    func branches(at rootURL: URL) async throws -> GitBranchSnapshot? {
        guard let repositoryRoot = try await repositoryRoot(at: rootURL) else { return nil }
        async let statusOutput = checkedRun(
            ["status", "--porcelain=v2", "--branch", "--untracked-files=no", "-z"],
            at: repositoryRoot
        )
        async let branchOutput = checkedRun(
            [
                "for-each-ref",
                "--format=%(refname)%1f%(refname:short)%1f%(objectname)%1f%(upstream:short)%1f%(upstream:track)%1f%(HEAD)%00",
                "refs/heads",
                "refs/remotes",
            ],
            at: repositoryRoot
        )
        let parsedStatus = GitStatusParser.parse(try await statusOutput.standardOutput)
        let parsedBranches = GitBranchParser.parse(try await branchOutput.standardOutput)
        return GitBranchSnapshot(
            currentBranch: parsedStatus.isDetached ? nil : parsedStatus.branch,
            upstream: parsedStatus.upstream,
            aheadCount: parsedStatus.aheadCount,
            behindCount: parsedStatus.behindCount,
            isDetached: parsedStatus.isDetached,
            isUnborn: parsedStatus.isUnborn,
            branches: parsedBranches
        )
    }

    @concurrent
    func diff(_ request: GitDiffRequest, at rootURL: URL) async throws -> GitFileDiff {
        let repositoryRoot = try await requireRepositoryRoot(at: rootURL)
        let snapshot = try await snapshot(at: repositoryRoot)
        let change = snapshot?.changes.first { $0.path == request.path }

        let arguments: [String]
        switch request.scope {
        case .workingTree:
            arguments =
                baseDiffArguments
                + (change?.isConflicted == true ? ["--ours"] : [])
                + ["--", request.path]
        case .staged:
            arguments = baseDiffArguments + ["--cached", "--", request.path]
        case .commit(let revision):
            let objectID = try await resolveCommit(revision, at: repositoryRoot)
            arguments = [
                "show", "--format=", "--no-ext-diff", "--no-color", "--find-renames", "--unified=3",
                objectID, "--", request.path,
            ]
        case .between(let base, let head):
            let baseID = try await resolveCommit(base, at: repositoryRoot)
            let headID = try await resolveCommit(head, at: repositoryRoot)
            arguments = baseDiffArguments + [baseID, headID, "--", request.path]
        }

        var output = try await checkedRun(
            arguments, at: repositoryRoot, maximumOutputBytes: 96 * 1_024 * 1_024)
        if case .workingTree = request.scope,
            output.standardOutput.isEmpty,
            change?.kind == .untracked
        {
            output = try await runner.run(
                arguments: [
                    "diff", "--no-index", "--no-ext-diff", "--no-color", "--unified=3", "--",
                    "/dev/null", request.path,
                ],
                at: repositoryRoot,
                maximumOutputBytes: 96 * 1_024 * 1_024
            )
            guard output.terminationStatus == 0 || output.terminationStatus == 1 else {
                throw commandError(output)
            }
        }

        return UnifiedDiffParser.parse(
            path: request.path,
            originalPath: change?.originalPath,
            patch: output.stdout
        )
    }

    @concurrent
    func history(at rootURL: URL, limit: Int = 100, offset: Int = 0) async throws -> GitHistoryPage
    {
        guard (1...500).contains(limit), offset >= 0 else {
            throw GitServiceError.invalidHistoryRange
        }
        let repositoryRoot = try await requireRepositoryRoot(at: rootURL)
        guard try await hasHead(at: repositoryRoot) else {
            return GitHistoryPage(commits: [], offset: offset, requestedCount: limit)
        }
        let format = "%H%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%s%x1f%D%x00"
        let output = try await checkedRun(
            [
                "log", "--date=iso-strict", "--decorate=short", "--max-count=\(limit)",
                "--skip=\(offset)", "--format=\(format)",
            ],
            at: repositoryRoot,
            maximumOutputBytes: 32 * 1_024 * 1_024
        )
        return GitHistoryPage(
            commits: GitHistoryParser.parse(output.standardOutput),
            offset: offset,
            requestedCount: limit
        )
    }

    @concurrent
    func commitChanges(_ revision: String, at rootURL: URL) async throws -> [GitCommitFileChange] {
        let repositoryRoot = try await requireRepositoryRoot(at: rootURL)
        let objectID = try await resolveCommit(revision, at: repositoryRoot)
        let output = try await checkedRun(
            [
                "diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "-z", "-M",
                objectID,
            ],
            at: repositoryRoot,
            maximumOutputBytes: 16 * 1_024 * 1_024
        )
        return GitCommitFilesParser.parse(output.standardOutput)
    }

    @concurrent
    func setStaged(_ staged: Bool, path: String, at rootURL: URL) async throws {
        try await setStaged(staged, paths: [path], at: rootURL)
    }

    /// Stages or unstages every path in one Git process, regardless of count.
    /// Pathspecs are streamed over stdin (`--pathspec-from-file=- --pathspec-file-nul`)
    /// rather than passed as argv, and each is prefixed `:(literal)` so paths
    /// containing pathspec-magic characters (`[`, `*`, leading `-`/`:`, ...)
    /// are matched literally instead of interpreted as glob patterns.
    @concurrent
    func setStaged(_ staged: Bool, paths: [String], at rootURL: URL) async throws {
        guard !paths.isEmpty else { return }
        let repositoryRoot = try await requireRepositoryRoot(at: rootURL)
        let pathspecStdin = Self.pathspecStdin(for: paths)
        if staged {
            _ = try await checkedRun(
                ["add", "--pathspec-from-file=-", "--pathspec-file-nul"],
                at: repositoryRoot,
                standardInput: pathspecStdin
            )
        } else if try await hasHead(at: repositoryRoot) {
            _ = try await checkedRun(
                ["reset", "-q", "HEAD", "--pathspec-from-file=-", "--pathspec-file-nul"],
                at: repositoryRoot,
                standardInput: pathspecStdin
            )
        } else {
            _ = try await checkedRun(
                [
                    "rm", "--cached", "-q", "--ignore-unmatch", "--pathspec-from-file=-",
                    "--pathspec-file-nul",
                ],
                at: repositoryRoot,
                standardInput: pathspecStdin
            )
        }
    }

    private static func pathspecStdin(for paths: [String]) -> Data {
        var data = Data()
        for path in paths {
            data.append(Data(":(literal)".utf8))
            data.append(Data(path.utf8))
            data.append(0)
        }
        return data
    }

    @concurrent
    func stageAll(at rootURL: URL) async throws {
        let repositoryRoot = try await requireRepositoryRoot(at: rootURL)
        _ = try await checkedRun(["add", "--all"], at: repositoryRoot)
    }

    @concurrent
    func commit(message: String, at rootURL: URL) async throws -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitServiceError.emptyCommitMessage }
        let repositoryRoot = try await requireRepositoryRoot(at: rootURL)
        let output = try await checkedRun(["commit", "-m", trimmed], at: repositoryRoot)
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @concurrent
    func createBranch(
        named name: String,
        startPoint: String? = nil,
        checkout: Bool = true,
        at rootURL: URL
    ) async throws {
        let repositoryRoot = try await requireRepositoryRoot(at: rootURL)
        try await validateBranchName(name, at: repositoryRoot)
        var arguments = checkout ? ["checkout", "-b", name] : ["branch", name]
        if let startPoint {
            arguments.append(try await resolveCommit(startPoint, at: repositoryRoot))
        }
        _ = try await checkedRun(arguments, at: repositoryRoot)
    }

    @concurrent
    func checkout(branch name: String, at rootURL: URL) async throws {
        let repositoryRoot = try await requireRepositoryRoot(at: rootURL)
        try await validateBranchName(name, at: repositoryRoot)
        _ = try await checkedRun(["checkout", name], at: repositoryRoot)
    }

    @concurrent
    func merge(
        branch name: String,
        strategy: GitMergeStrategy = .defaultMerge,
        at rootURL: URL
    ) async throws -> GitOperationResult {
        let repositoryRoot = try await requireRepositoryRoot(at: rootURL)
        _ = try await resolveCommit(name, at: repositoryRoot)
        var arguments = ["merge", "--no-edit"]
        switch strategy {
        case .defaultMerge: break
        case .fastForwardOnly: arguments.append("--ff-only")
        case .noFastForward: arguments.append("--no-ff")
        }
        arguments += ["--", name]
        let output = try await checkedRun(arguments, at: repositoryRoot)
        return GitOperationResult(standardOutput: output.stdout, standardError: output.stderr)
    }

    @concurrent
    func fetch(_ request: GitFetchRequest = GitFetchRequest(), at rootURL: URL) async throws
        -> GitOperationResult
    {
        let repositoryRoot = try await requireRepositoryRoot(at: rootURL)
        var arguments = ["fetch"]
        if request.prune { arguments.append("--prune") }
        if let remote = request.remote {
            try await validateRemoteName(remote, at: repositoryRoot)
            arguments.append(remote)
        } else {
            arguments.append("--all")
        }
        let output = try await checkedRun(arguments, at: repositoryRoot)
        return GitOperationResult(standardOutput: output.stdout, standardError: output.stderr)
    }

    @concurrent
    func pull(_ request: GitPullRequest = GitPullRequest(), at rootURL: URL) async throws
        -> GitOperationResult
    {
        let repositoryRoot = try await requireRepositoryRoot(at: rootURL)
        var arguments = ["pull"]
        switch request.strategy {
        case .merge: arguments.append("--no-rebase")
        case .rebase: arguments.append("--rebase")
        case .fastForwardOnly: arguments.append("--ff-only")
        }
        if let remote = request.remote {
            try await validateRemoteName(remote, at: repositoryRoot)
            arguments.append(remote)
        }
        if let branch = request.branch {
            guard request.remote != nil else { throw GitServiceError.branchRequiresRemote }
            try await validateBranchName(branch, at: repositoryRoot)
            arguments.append(branch)
        }
        let output = try await checkedRun(arguments, at: repositoryRoot)
        return GitOperationResult(standardOutput: output.stdout, standardError: output.stderr)
    }

    @concurrent
    func push(_ request: GitPushRequest = GitPushRequest(), at rootURL: URL) async throws
        -> GitOperationResult
    {
        let repositoryRoot = try await requireRepositoryRoot(at: rootURL)
        var arguments = ["push"]
        if request.setUpstream { arguments.append("--set-upstream") }
        if let remote = request.remote {
            try await validateRemoteName(remote, at: repositoryRoot)
            arguments.append(remote)
        } else if request.setUpstream {
            throw GitServiceError.upstreamRequiresRemoteAndBranch
        }
        if let branch = request.branch {
            guard request.remote != nil else { throw GitServiceError.branchRequiresRemote }
            try await validateBranchName(branch, at: repositoryRoot)
            arguments.append(branch)
        } else if request.setUpstream {
            throw GitServiceError.upstreamRequiresRemoteAndBranch
        }
        let output = try await checkedRun(arguments, at: repositoryRoot)
        return GitOperationResult(standardOutput: output.stdout, standardError: output.stderr)
    }

    /// Per-line change markers for one tracked file's working tree, parsed
    /// from `--unified=0` hunk headers only. Callers resolve the repository
    /// root and repo-relative path first so no extra process is spawned.
    @concurrent
    func lineChanges(forRelativePath path: String, at repositoryRoot: URL) async throws
        -> GitGutterLineChanges
    {
        let output = try await checkedRun(
            ["diff", "--no-ext-diff", "--no-color", "--unified=0", "--", path],
            at: repositoryRoot,
            maximumOutputBytes: 16 * 1_024 * 1_024
        )
        return GitGutterHunkParser.parse(output.stdout)
    }

    /// Added/deleted line counts per path, merged across unstaged and staged
    /// `git diff --numstat -z` output (two bounded processes total,
    /// independent of changeset size). Untracked files never appear here;
    /// callers fall back to on-disk file size for those. Used only to order
    /// and budget AI commit-prompt diff fetches, never to gate them.
    @concurrent
    func changeLineStats(at rootURL: URL) async throws -> [String: GitLineStats] {
        let repositoryRoot = try await requireRepositoryRoot(at: rootURL)
        async let workingTree = checkedRun(
            ["diff", "--no-ext-diff", "--find-renames", "--numstat", "-z"],
            at: repositoryRoot,
            maximumOutputBytes: 8 * 1_024 * 1_024
        )
        async let staged = checkedRun(
            ["diff", "--no-ext-diff", "--find-renames", "--numstat", "-z", "--cached"],
            at: repositoryRoot,
            maximumOutputBytes: 8 * 1_024 * 1_024
        )
        let workingStats = GitNumstatParser.parse(try await workingTree.standardOutput)
        let stagedStats = GitNumstatParser.parse(try await staged.standardOutput)
        var merged = workingStats
        for (path, stats) in stagedStats {
            merged[path] = GitLineStats.merge(merged[path], stats)
        }
        return merged
    }

    private var baseDiffArguments: [String] {
        ["diff", "--no-ext-diff", "--no-color", "--find-renames", "--unified=3"]
    }

    private func repositoryRoot(at directoryURL: URL) async throws -> URL? {
        let output = try await runner.run(
            arguments: ["rev-parse", "--show-toplevel"],
            at: directoryURL,
            maximumOutputBytes: 1_024 * 1_024
        )
        guard output.terminationStatus == 0 else { return nil }
        let path = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    private func requireRepositoryRoot(at directoryURL: URL) async throws -> URL {
        guard let root = try await repositoryRoot(at: directoryURL) else {
            throw GitServiceError.notARepository
        }
        return root
    }

    private func hasHead(at repositoryRoot: URL) async throws -> Bool {
        let output = try await runner.run(
            arguments: ["rev-parse", "--verify", "HEAD^{commit}"],
            at: repositoryRoot,
            maximumOutputBytes: 1_024 * 1_024
        )
        return output.terminationStatus == 0
    }

    private func resolveCommit(_ revision: String, at repositoryRoot: URL) async throws -> String {
        guard !revision.isEmpty, !revision.hasPrefix("-") else {
            throw GitServiceError.invalidRevision(revision)
        }
        let output = try await runner.run(
            arguments: ["rev-parse", "--verify", "\(revision)^{commit}"],
            at: repositoryRoot,
            maximumOutputBytes: 1_024 * 1_024
        )
        guard output.terminationStatus == 0 else { throw GitServiceError.invalidRevision(revision) }
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validateBranchName(_ name: String, at repositoryRoot: URL) async throws {
        guard !name.isEmpty, !name.hasPrefix("-") else {
            throw GitServiceError.invalidBranchName(name)
        }
        let output = try await runner.run(
            arguments: ["check-ref-format", "--branch", name],
            at: repositoryRoot,
            maximumOutputBytes: 1_024 * 1_024
        )
        guard output.terminationStatus == 0 else { throw GitServiceError.invalidBranchName(name) }
    }

    private func validateRemoteName(_ name: String, at repositoryRoot: URL) async throws {
        guard !name.isEmpty, !name.hasPrefix("-") else { throw GitServiceError.invalidRemote(name) }
        let output = try await runner.run(
            arguments: ["remote", "get-url", name],
            at: repositoryRoot,
            maximumOutputBytes: 1_024 * 1_024
        )
        guard output.terminationStatus == 0 else { throw GitServiceError.invalidRemote(name) }
    }

    private func checkedRun(
        _ arguments: [String],
        at repositoryRoot: URL,
        standardInput: Data? = nil,
        maximumOutputBytes: Int = 64 * 1_024 * 1_024
    ) async throws -> GitCommandOutput {
        let output = try await runner.run(
            arguments: arguments,
            at: repositoryRoot,
            standardInput: standardInput,
            maximumOutputBytes: maximumOutputBytes
        )
        guard output.terminationStatus == 0 else { throw commandError(output) }
        return output
    }

    private func commandError(_ output: GitCommandOutput) -> GitServiceError {
        let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .commandFailed(
            message.isEmpty ? "Git command failed (\(output.terminationStatus))." : message)
    }
}

nonisolated enum GitServiceError: LocalizedError, Equatable {
    case branchRequiresRemote
    case captureCreationFailed
    case commandFailed(String)
    case couldNotLaunch(String)
    case emptyCommitMessage
    case invalidBranchName(String)
    case invalidHistoryRange
    case invalidRemote(String)
    case invalidRevision(String)
    case notARepository
    case outputTooLarge(limit: Int)
    case upstreamRequiresRemoteAndBranch

    var errorDescription: String? {
        switch self {
        case .branchRequiresRemote:
            "Choose a remote before specifying a branch."
        case .captureCreationFailed:
            "Rafu could not create temporary files for Git output."
        case .commandFailed(let message):
            message.isEmpty ? "Git command failed." : message
        case .couldNotLaunch(let message):
            "Rafu could not launch Git: \(message)"
        case .emptyCommitMessage:
            "Enter a commit message."
        case .invalidBranchName(let name):
            "“\(name)” is not a valid Git branch name."
        case .invalidHistoryRange:
            "Git history pages must request between 1 and 500 commits with a nonnegative offset."
        case .invalidRemote(let name):
            "“\(name)” is not a configured Git remote."
        case .invalidRevision(let revision):
            "“\(revision)” does not identify a commit."
        case .notARepository:
            "The selected folder is not inside a Git repository."
        case .outputTooLarge(let limit):
            "Git produced more than \(limit) bytes of output. Narrow the operation and try again."
        case .upstreamRequiresRemoteAndBranch:
            "Setting an upstream requires both a remote and a branch."
        }
    }
}
