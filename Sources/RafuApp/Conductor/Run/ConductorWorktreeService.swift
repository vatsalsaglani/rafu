import Foundation

/// A resolved execution location for one run. Planning is read-only so the
/// controller can persist the exact base and intended branch before Git
/// creates either resource.
nonisolated struct ConductorWorkspacePlan: Equatable, Sendable {
    let repositoryRoot: URL
    let executionRoot: URL
    let baseCommit: String
    let branchName: String?
    let worktreeURL: URL?
}

nonisolated enum ConductorWorktreeDiscardResult: Equatable, Sendable {
    case removed
    case confirmationRequired
}

/// Structural worktree failures only. Git stderr can include repository
/// paths, hook output, or other user-controlled text, so it is never copied
/// into a run manifest or Rafu log.
nonisolated enum ConductorWorktreeError: Error, Equatable, LocalizedError, Sendable {
    case baseDoesNotMatchReadOnlyCheckout
    case invalidBaseReference
    case invalidRunID
    case repositoryHasNoCommit
    case repositoryUnavailable
    case unableToCreateWorktree
    case unableToDiscardWorktree
    case worktreeLocationOccupied
    case worktreeOwnershipChanged

    var errorDescription: String? {
        switch self {
        case .baseDoesNotMatchReadOnlyCheckout:
            "A read-only run must use the commit currently checked out in the workspace."
        case .invalidBaseReference:
            "The selected base does not identify a commit."
        case .invalidRunID:
            "The generated run identifier is invalid."
        case .repositoryHasNoCommit:
            "Create an initial commit before starting a Conductor run."
        case .repositoryUnavailable:
            "Open a Git workspace before starting a Conductor run."
        case .unableToCreateWorktree:
            "Rafu could not create the run worktree."
        case .unableToDiscardWorktree:
            "Rafu could not discard the run worktree."
        case .worktreeLocationOccupied:
            "The run worktree location already exists."
        case .worktreeOwnershipChanged:
            "The run worktree no longer matches the branch Rafu created."
        }
    }
}

/// Git-backed worktree lifecycle for C1 runs.
///
/// Every Git invocation uses an executable plus argv. Destructive discard is
/// limited to a path still registered to the expected run branch. Worktree
/// removal always goes through `GitService.removeWorktree`, which never adds
/// `--force`.
nonisolated struct ConductorWorktreeService: Sendable {
    private let gitService = GitService()
    private let runner = GitCommandRunner()

    @concurrent
    func plan(
        workspaceRoot: URL,
        runID: String,
        autonomy: ConductorAutonomy,
        baseReference: String
    ) async throws -> ConductorWorkspacePlan {
        guard ConductorRunStore.isValidRunID(runID) else {
            throw ConductorWorktreeError.invalidRunID
        }
        guard
            let snapshot = try await gitService.snapshot(at: workspaceRoot),
            let repositoryRoot = snapshot.repositoryRoot
        else {
            throw ConductorWorktreeError.repositoryUnavailable
        }
        guard let headCommit = snapshot.headOID, !headCommit.isEmpty else {
            throw ConductorWorktreeError.repositoryHasNoCommit
        }

        let baseCommit = try await resolveCommit(
            baseReference, repositoryRoot: repositoryRoot)
        switch autonomy {
        case .readOnly:
            guard baseCommit == headCommit else {
                throw ConductorWorktreeError.baseDoesNotMatchReadOnlyCheckout
            }
            return ConductorWorkspacePlan(
                repositoryRoot: repositoryRoot,
                executionRoot: repositoryRoot,
                baseCommit: baseCommit,
                branchName: nil,
                worktreeURL: nil)
        case .worktreeWrite:
            let branchName = "rafu/run-\(runID)"
            let worktreeURL = Self.worktreeURL(
                repositoryRoot: repositoryRoot, runID: runID)
            guard !FileManager.default.fileExists(atPath: worktreeURL.path) else {
                throw ConductorWorktreeError.worktreeLocationOccupied
            }
            return ConductorWorkspacePlan(
                repositoryRoot: repositoryRoot,
                executionRoot: worktreeURL,
                baseCommit: baseCommit,
                branchName: branchName,
                worktreeURL: worktreeURL)
        }
    }

    @concurrent
    func materialize(_ plan: ConductorWorkspacePlan) async throws {
        guard let branchName = plan.branchName, let worktreeURL = plan.worktreeURL else {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: worktreeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try await gitService.createBranch(
                named: branchName,
                startPoint: plan.baseCommit,
                checkout: false,
                at: plan.repositoryRoot)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ConductorWorktreeError.unableToCreateWorktree
        }

        do {
            try await gitService.addWorktree(
                path: worktreeURL,
                branch: branchName,
                createBranch: false,
                at: plan.repositoryRoot)
            try await verify(plan, requiresBaseCommit: true)
        } catch is CancellationError {
            // Abort never removes a worktree that Git may already have
            // created. Its exact branch/path attribution remains available
            // for explicit user cleanup.
            throw CancellationError()
        } catch {
            await rollbackNewWorktree(plan)
            throw ConductorWorktreeError.unableToCreateWorktree
        }
    }

    @concurrent
    func discard(
        _ plan: ConductorWorkspacePlan,
        confirmedDirty: Bool
    ) async throws -> ConductorWorktreeDiscardResult {
        guard let worktreeURL = plan.worktreeURL, let branchName = plan.branchName else {
            return .removed
        }
        try await verify(plan)
        guard let snapshot = try await gitService.snapshot(at: worktreeURL) else {
            throw ConductorWorktreeError.worktreeOwnershipChanged
        }

        if !snapshot.changes.isEmpty {
            guard confirmedDirty else { return .confirmationRequired }
            try await checkedRun(
                ["reset", "--hard", plan.baseCommit], at: worktreeURL)
            try await checkedRun(["clean", "-fd"], at: worktreeURL)
            try await verify(plan, requiresBaseCommit: true)
            guard
                let cleaned = try await gitService.snapshot(at: worktreeURL),
                cleaned.changes.isEmpty
            else {
                throw ConductorWorktreeError.unableToDiscardWorktree
            }
        }

        do {
            try await gitService.removeWorktree(
                path: worktreeURL.path, at: plan.repositoryRoot)
            try await checkedRun(
                ["branch", "-D", branchName], at: plan.repositoryRoot)
            return .removed
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ConductorWorktreeError.unableToDiscardWorktree
        }
    }

    private func resolveCommit(
        _ reference: String,
        repositoryRoot: URL
    ) async throws -> String {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-"), !trimmed.utf8.contains(0) else {
            throw ConductorWorktreeError.invalidBaseReference
        }
        let output = try await runner.run(
            arguments: ["rev-parse", "--verify", "\(trimmed)^{commit}"],
            at: repositoryRoot,
            maximumOutputBytes: 4_096)
        let commit = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let hexadecimalDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard
            output.terminationStatus == 0,
            commit.unicodeScalars.count == 40,
            commit.unicodeScalars.allSatisfy(hexadecimalDigits.contains)
        else {
            throw ConductorWorktreeError.invalidBaseReference
        }
        return commit
    }

    private func verify(
        _ plan: ConductorWorkspacePlan,
        requiresBaseCommit: Bool = false
    ) async throws {
        guard let worktreeURL = plan.worktreeURL, let branchName = plan.branchName else {
            return
        }
        let expectedPath = worktreeURL.resolvingSymlinksInPath().standardizedFileURL.path
        let worktrees = try await gitService.worktrees(at: plan.repositoryRoot)
        guard
            let worktree = worktrees.first(where: {
                URL(fileURLWithPath: $0.path)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL.path == expectedPath
            }),
            worktree.branch == branchName,
            !requiresBaseCommit || worktree.headOID == plan.baseCommit
        else {
            throw ConductorWorktreeError.worktreeOwnershipChanged
        }
    }

    private func checkedRun(_ arguments: [String], at root: URL) async throws {
        let output = try await runner.run(
            arguments: arguments,
            at: root,
            maximumOutputBytes: 4 * 1_024 * 1_024)
        guard output.terminationStatus == 0 else {
            throw ConductorWorktreeError.unableToDiscardWorktree
        }
    }

    private func rollbackNewWorktree(_ plan: ConductorWorkspacePlan) async {
        if let worktreeURL = plan.worktreeURL,
            FileManager.default.fileExists(atPath: worktreeURL.path),
            let snapshot = try? await gitService.snapshot(at: worktreeURL),
            snapshot.changes.isEmpty
        {
            try? await gitService.removeWorktree(
                path: worktreeURL.path, at: plan.repositoryRoot)
        }
        if let branchName = plan.branchName {
            _ = try? await runner.run(
                arguments: ["branch", "-D", branchName],
                at: plan.repositoryRoot,
                maximumOutputBytes: 4_096)
        }
    }

    private static func worktreeURL(repositoryRoot: URL, runID: String) -> URL {
        let repositoryName = repositoryRoot.lastPathComponent
        return repositoryRoot.deletingLastPathComponent()
            .appending(path: ".rafu-worktrees", directoryHint: .isDirectory)
            .appending(
                path: "\(repositoryName)-\(runID)",
                directoryHint: .isDirectory)
    }
}
