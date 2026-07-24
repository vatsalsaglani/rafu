import Foundation

nonisolated struct ConductorMergeGateFile: Equatable, Hashable, Identifiable, Sendable {
    let path: String
    let isUntracked: Bool

    var id: String { path }
}

nonisolated enum ConductorMergeGateError: Error, Equatable, LocalizedError, Sendable {
    case applyRejected
    case appliedButCleanupFailed
    case patchGenerationFailed
    case patchTooLarge
    case targetWorkspaceChanged
    case unsafePath
    case worktreeUnavailable

    var errorDescription: String? {
        switch self {
        case .applyRejected:
            "Git rejected the run patch without changing the workspace."
        case .appliedButCleanupFailed:
            "The patch was applied, but the run worktree still needs cleanup."
        case .patchGenerationFailed:
            "Rafu could not generate the run worktree patch."
        case .patchTooLarge:
            "The run patch is too large to apply in one operation."
        case .targetWorkspaceChanged:
            "The workspace changed after this run started. Review those changes before applying."
        case .unsafePath:
            "The run diff contains a path Rafu cannot apply safely."
        case .worktreeUnavailable:
            "The run worktree is no longer available."
        }
    }
}

nonisolated enum ConductorMergeApplyResult: Equatable, Sendable {
    case applied
    case noChanges
}

/// Trusted Git evidence for the merge gate. The handoff artifact is never
/// consulted here: changed paths, per-file diffs, and the patch all come
/// directly from the attributed run worktree.
nonisolated struct ConductorMergeGateService: Sendable {
    private static let maximumPatchBytes = 96 * 1_024 * 1_024

    private let gitService = GitService()
    private let runner = GitCommandRunner()
    private let worktreeService = ConductorWorktreeService()

    @concurrent
    func files(for plan: ConductorWorkspacePlan) async throws -> [ConductorMergeGateFile] {
        guard let worktreeURL = plan.worktreeURL else { return [] }
        guard FileManager.default.fileExists(atPath: worktreeURL.path) else {
            throw ConductorMergeGateError.worktreeUnavailable
        }

        let trackedOutput = try await checkedOutput(
            [
                "diff", "--name-only", "-z", "--find-renames", plan.baseCommit, "--",
            ],
            at: worktreeURL)
        let untrackedOutput = try await checkedOutput(
            ["ls-files", "--others", "--exclude-standard", "-z"],
            at: worktreeURL)
        let tracked = try paths(from: trackedOutput.standardOutput)
        let untracked = try paths(from: untrackedOutput.standardOutput)
        let untrackedSet = Set(untracked)
        return Set(tracked + untracked)
            .map {
                ConductorMergeGateFile(
                    path: $0,
                    isUntracked: untrackedSet.contains($0))
            }
            .sorted { $0.path < $1.path }
    }

    @concurrent
    func diff(
        for file: ConductorMergeGateFile,
        plan: ConductorWorkspacePlan
    ) async throws -> GitFileDiff {
        guard let worktreeURL = plan.worktreeURL else {
            throw ConductorMergeGateError.worktreeUnavailable
        }
        guard Self.isSafeRelativePath(file.path) else {
            throw ConductorMergeGateError.unsafePath
        }

        let output: GitCommandOutput
        if file.isUntracked {
            output = try await runner.run(
                arguments: [
                    "diff", "--no-index", "--no-ext-diff", "--no-color",
                    "--find-renames", "--unified=3", "--", "/dev/null", file.path,
                ],
                at: worktreeURL,
                maximumOutputBytes: Self.maximumPatchBytes)
            guard output.terminationStatus == 0 || output.terminationStatus == 1 else {
                throw ConductorMergeGateError.patchGenerationFailed
            }
        } else {
            output = try await checkedOutput(
                [
                    "diff", "--no-ext-diff", "--no-color", "--find-renames",
                    "--unified=3", plan.baseCommit, "--", file.path,
                ],
                at: worktreeURL)
        }
        return UnifiedDiffParser.parse(
            path: file.path,
            originalPath: nil,
            patch: output.stdout)
    }

    @concurrent
    func apply(_ plan: ConductorWorkspacePlan) async throws -> ConductorMergeApplyResult {
        guard let worktreeURL = plan.worktreeURL else { return .noChanges }
        try await requireSafeTarget(plan)
        let patch = try await patch(plan: plan, worktreeURL: worktreeURL)

        if !patch.isEmpty {
            let check = try await runner.run(
                arguments: ["apply", "--check", "--binary", "--whitespace=nowarn", "-"],
                at: plan.repositoryRoot,
                standardInput: patch,
                maximumOutputBytes: 4 * 1_024 * 1_024)
            guard check.terminationStatus == 0 else {
                throw ConductorMergeGateError.applyRejected
            }
            let apply = try await runner.run(
                arguments: ["apply", "--binary", "--whitespace=nowarn", "-"],
                at: plan.repositoryRoot,
                standardInput: patch,
                maximumOutputBytes: 4 * 1_024 * 1_024)
            guard apply.terminationStatus == 0 else {
                throw ConductorMergeGateError.applyRejected
            }
        }

        do {
            let cleanup = try await worktreeService.removeAfterSuccessfulApply(plan)
            guard cleanup == .removed else {
                throw ConductorMergeGateError.appliedButCleanupFailed
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ConductorMergeGateError {
            throw error
        } catch {
            throw ConductorMergeGateError.appliedButCleanupFailed
        }
        return patch.isEmpty ? .noChanges : .applied
    }

    @concurrent
    private func patch(
        plan: ConductorWorkspacePlan,
        worktreeURL: URL
    ) async throws -> Data {
        let tracked = try await checkedOutput(
            [
                "diff", "--binary", "--full-index", "--find-renames",
                plan.baseCommit, "--",
            ],
            at: worktreeURL)
        var patch = tracked.standardOutput
        guard patch.count <= Self.maximumPatchBytes else {
            throw ConductorMergeGateError.patchTooLarge
        }

        let untrackedOutput = try await checkedOutput(
            ["ls-files", "--others", "--exclude-standard", "-z"],
            at: worktreeURL)
        for path in try paths(from: untrackedOutput.standardOutput) {
            let output = try await runner.run(
                arguments: [
                    "diff", "--no-index", "--binary", "--full-index",
                    "--", "/dev/null", path,
                ],
                at: worktreeURL,
                maximumOutputBytes: Self.maximumPatchBytes)
            guard output.terminationStatus == 0 || output.terminationStatus == 1 else {
                throw ConductorMergeGateError.patchGenerationFailed
            }
            guard patch.count + output.standardOutput.count <= Self.maximumPatchBytes else {
                throw ConductorMergeGateError.patchTooLarge
            }
            patch.append(output.standardOutput)
        }
        return patch
    }

    private func requireSafeTarget(_ plan: ConductorWorkspacePlan) async throws {
        guard
            let snapshot = try await gitService.snapshot(at: plan.repositoryRoot),
            snapshot.repositoryRoot?.standardizedFileURL
                == plan.repositoryRoot.standardizedFileURL,
            snapshot.headOID == plan.baseCommit
        else {
            throw ConductorMergeGateError.targetWorkspaceChanged
        }
        for change in snapshot.changes {
            guard
                change.path == ".rafu/.gitignore",
                change.kind == .untracked,
                let contents = try? Data(
                    contentsOf: plan.repositoryRoot.appending(path: change.path)),
                contents == Data(RafuDotDirectory.defaultGitignoreContents.utf8)
            else {
                throw ConductorMergeGateError.targetWorkspaceChanged
            }
        }
    }

    private func checkedOutput(
        _ arguments: [String],
        at root: URL
    ) async throws -> GitCommandOutput {
        let output = try await runner.run(
            arguments: arguments,
            at: root,
            maximumOutputBytes: Self.maximumPatchBytes)
        guard output.terminationStatus == 0 else {
            throw ConductorMergeGateError.patchGenerationFailed
        }
        return output
    }

    private func paths(from data: Data) throws -> [String] {
        try data.split(separator: 0).map { bytes in
            guard
                let path = String(data: bytes, encoding: .utf8),
                Self.isSafeRelativePath(path)
            else {
                throw ConductorMergeGateError.unsafePath
            }
            return path
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0) else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

@MainActor
extension WorkspaceSession {
    func presentConductorDiff(
        _ diff: GitFileDiff,
        file: ConductorMergeGateFile,
        plan: ConductorWorkspacePlan
    ) {
        gitOpenDiff = GitOpenDiff(
            title: "Run Diff • \((file.path as NSString).lastPathComponent)",
            subtitle: "\(file.path) • \(String(plan.baseCommit.prefix(8))) → run worktree",
            diff: diff,
            identity: "conductor:\(plan.branchName ?? plan.baseCommit):\(file.path)",
            scope: .between(
                base: plan.baseCommit,
                head: plan.branchName ?? plan.baseCommit))
        selectedDocumentID = nil
        selectedTreePath = nil
    }
}
