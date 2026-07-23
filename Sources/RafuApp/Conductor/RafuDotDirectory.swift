import Foundation

/// Why `.rafu/` could not be prepared.
nonisolated enum RafuDotDirectoryError: Error, Equatable, LocalizedError, Sendable {
    /// A path Rafu needs as a directory already exists as something else.
    /// Seeding STOPS here — it never deletes or replaces what the user has.
    case pathIsNotADirectory(String)

    var errorDescription: String? {
        switch self {
        case .pathIsNotADirectory(let path):
            "\"\(path)\" already exists and is not a directory."
        }
    }
}

/// The in-repo `.rafu/` contract (ADR 0018 establishes agents, workflows,
/// and runs as public contract) resolved against one workspace root.
///
/// `seed()` is NOT called when a workspace opens. Rafu must not write into a
/// user's repository merely because a folder was opened — AGENTS.md's
/// explicit-control invariant, and ADR 0018's "nothing executes without a
/// visible, user-initiated run". C1 calls it from the run-start path.
nonisolated struct RafuDotDirectory: Sendable {
    let workspaceRoot: URL

    init(workspaceRoot: URL) {
        self.workspaceRoot = workspaceRoot
    }

    var directoryURL: URL {
        workspaceRoot.appending(path: ".rafu", directoryHint: .isDirectory)
    }
    var agentsURL: URL {
        directoryURL.appending(path: "agents", directoryHint: .isDirectory)
    }
    var workflowsURL: URL {
        directoryURL.appending(path: "workflows", directoryHint: .isDirectory)
    }
    var runsURL: URL {
        directoryURL.appending(path: "runs", directoryHint: .isDirectory)
    }
    /// `.rafu/.gitignore` — scoped to `.rafu/` so the repository's OWN
    /// top-level `.gitignore` is never touched.
    var gitignoreURL: URL {
        directoryURL.appending(path: ".gitignore", directoryHint: .notDirectory)
    }

    func runDirectoryURL(for runID: String) -> URL {
        runsURL.appending(path: runID, directoryHint: .isDirectory)
    }

    /// What `seed()` actually changed, so callers can report honestly
    /// instead of claiming to have created something that was already there.
    nonisolated struct SeedResult: Equatable, Sendable {
        /// Workspace-relative paths this call created, in creation order.
        let createdDirectories: [String]
        let gitignore: GitignoreOutcome

        nonisolated enum GitignoreOutcome: Equatable, Sendable {
            case created
            /// Left BYTE-FOR-BYTE alone.
            case alreadyPresent
        }

        var didChangeAnything: Bool {
            !createdDirectories.isEmpty || gitignore == .created
        }
    }

    /// Default `.rafu/.gitignore`. `runs/` is relative to `.rafu/`, so this
    /// ignores run evidence without saying anything about the rest of the
    /// repository (ADR 0018: gitignored by default, with a user choice to
    /// commit).
    static let defaultGitignoreContents = """
        # Rafu Conductor run evidence: manifests, handoff artifacts, patches,
        # and captured CLI output. Delete the line below to commit runs.
        runs/

        """

    /// Creates `.rafu/{agents,workflows,runs}` and, only when it does not
    /// already exist, `.rafu/.gitignore`.
    ///
    /// Idempotent by construction and deliberately NON-DESTRUCTIVE:
    /// - an existing `.rafu/.gitignore` is left byte-for-byte alone, never
    ///   appended to or rewritten;
    /// - no `.rafu/agents/*.md` or `.rafu/workflows/*.md` is ever created or
    ///   overwritten (bundled templates are C6's scope);
    /// - the repository's top-level `.gitignore` is never read or written;
    /// - a path that exists with the wrong type throws instead of being
    ///   removed.
    @concurrent
    func seed() async throws -> SeedResult {
        let manager = FileManager.default
        let required: [(relative: String, url: URL)] = [
            (".rafu", directoryURL),
            (".rafu/agents", agentsURL),
            (".rafu/workflows", workflowsURL),
            (".rafu/runs", runsURL),
        ]

        // Classify everything BEFORE creating anything, so a wrong-type path
        // aborts the whole seed rather than leaving it half-applied.
        var created: [String] = []
        for entry in required {
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: entry.url.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else {
                    throw RafuDotDirectoryError.pathIsNotADirectory(entry.url.path)
                }
            } else {
                created.append(entry.relative)
            }
        }
        for entry in required {
            try manager.createDirectory(at: entry.url, withIntermediateDirectories: true)
        }

        let gitignore: SeedResult.GitignoreOutcome
        if manager.fileExists(atPath: gitignoreURL.path) {
            gitignore = .alreadyPresent
        } else {
            try Data(Self.defaultGitignoreContents.utf8)
                .write(to: gitignoreURL, options: .atomic)
            gitignore = .created
        }
        return SeedResult(createdDirectories: created, gitignore: gitignore)
    }
}
