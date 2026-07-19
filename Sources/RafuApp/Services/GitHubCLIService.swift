import Foundation

/// Locates a local install of GitHub's `gh` CLI. Checked in priority order:
/// the two most common Homebrew prefixes, `/usr/bin/gh` (rare but possible
/// on a manually provisioned machine), then `$PATH`. Detection only — Rafu
/// never installs or updates `gh`.
nonisolated enum GitHubCLILocator {
    /// Checked in this order, ahead of `$PATH`, because both are common
    /// Homebrew prefixes a shell's `$PATH` may not include yet (a fresh
    /// terminal launched before `.zprofile` runs, or Rafu itself launched
    /// from Finder with a minimal inherited environment).
    static let defaultFixedCandidates = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh",
    ]

    /// `fixedCandidates` is injectable (defaulting to `defaultFixedCandidates`)
    /// purely so tests can exercise precedence ordering without depending on
    /// the real `/opt/homebrew` or `/usr/local` prefixes existing on the
    /// machine running the test.
    static func locate(
        fixedCandidates: [String] = defaultFixedCandidates,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        for path in fixedCandidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in pathDirectories {
            let candidate = URL(fileURLWithPath: directory).appending(path: "gh")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

nonisolated struct GitHubAccount: Equatable, Sendable {
    var login: String
    var name: String?
    var avatarURL: URL?
}

nonisolated enum GitHubRepositoryVisibility: Sendable {
    case `private`
    case `public`

    fileprivate var argument: String {
        switch self {
        case .private: "--private"
        case .public: "--public"
        }
    }
}

nonisolated enum GitHubCLIError: LocalizedError, Equatable {
    case notInstalled
    case notAuthenticated
    case remoteAlreadyExists
    case malformedResponse
    case couldNotLaunch(String)
    case commandFailed(String)
    case invalidRepositoryName(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "GitHub CLI (gh) was not found. Install it from https://cli.github.com, then try again."
        case .notAuthenticated:
            // Rafu never runs an interactive sign-in flow — surfacing the
            // exact terminal command is the honest, explicit alternative.
            "Not signed in to GitHub CLI. Run “gh auth login” in a terminal, then refresh."
        case .remoteAlreadyExists:
            "A remote named “origin” already exists for this repository."
        case .malformedResponse:
            "GitHub CLI returned a response Rafu could not read."
        case .couldNotLaunch(let message):
            "Rafu could not launch GitHub CLI: \(message)"
        case .commandFailed(let message):
            message.isEmpty ? "GitHub CLI command failed." : message
        case .invalidRepositoryName(let name):
            "“\(name)” is not a valid repository name."
        }
    }
}

nonisolated struct GitHubCommandOutput: Sendable {
    let arguments: [String]
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data

    var stdout: String { String(decoding: standardOutput, as: UTF8.self) }
    var stderr: String { String(decoding: standardError, as: UTF8.self) }
}

/// Explicit, user-driven `gh` invocations: resolving the authenticated
/// account and publishing a repository with no origin yet. Never runs `gh
/// auth login` or any other interactive flow, never passes `--show-token`,
/// and never logs stdout/stderr — callers may surface the mapped
/// `GitHubCLIError` description to the user, exactly like `GitServiceError`
/// already does for `git`.
nonisolated struct GitHubCLIService: Sendable {
    /// `nil` when `gh` could not be located — every call throws `.notInstalled`
    /// rather than guessing a path that may not exist.
    private let executableURL: URL?

    init(executableURL: URL? = GitHubCLILocator.locate()) {
        self.executableURL = executableURL
    }

    @concurrent
    func account() async throws -> GitHubAccount {
        let output = try await run(["api", "user"])
        guard output.terminationStatus == 0 else { throw Self.mapError(output) }
        return try Self.parseAccount(output.standardOutput)
    }

    /// Decodes `gh api user`'s JSON body. Pure and process-free so parsing
    /// edge cases (missing fields, malformed JSON, an unreasonably large
    /// body) are unit-testable without spawning `gh`.
    static func parseAccount(_ data: Data) throws -> GitHubAccount {
        guard data.count <= 1_024 * 1_024 else { throw GitHubCLIError.malformedResponse }
        struct Response: Decodable {
            let login: String
            let name: String?
            let avatarURL: String?

            enum CodingKeys: String, CodingKey {
                case login, name
                case avatarURL = "avatar_url"
            }
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
            !response.login.isEmpty
        else {
            throw GitHubCLIError.malformedResponse
        }
        return GitHubAccount(
            login: response.login,
            name: response.name,
            avatarURL: response.avatarURL.flatMap(URL.init(string:))
        )
    }

    /// Creates a GitHub repository from the workspace at `rootURL`, adds it
    /// as the `origin` remote, and pushes the current branch — one explicit,
    /// user-confirmed `gh repo create … --push` invocation (see
    /// `publishArguments(name:visibility:)`).
    @concurrent
    func publish(
        name: String,
        visibility: GitHubRepositoryVisibility,
        at rootURL: URL
    ) async throws {
        try Self.validateRepositoryName(name)
        let output = try await run(
            Self.publishArguments(name: name, visibility: visibility), at: rootURL)
        guard output.terminationStatus == 0 else { throw Self.mapError(output) }
    }

    /// Pure argument construction, unit-testable without spawning `gh`.
    /// `--push` is always present — the coordinator only calls `publish`
    /// from behind an explicit sheet confirmation, never automatically.
    static func publishArguments(
        name: String,
        visibility: GitHubRepositoryVisibility
    ) -> [String] {
        [
            "repo", "create", name,
            "--source", ".",
            visibility.argument,
            "--remote", "origin",
            "--push",
        ]
    }

    static func validateRepositoryName(_ name: String) throws {
        guard !name.isEmpty,
            !name.hasPrefix("-"),
            name.utf8.count <= 100,
            !name.contains(where: { $0.isWhitespace || $0.isNewline })
        else {
            throw GitHubCLIError.invalidRepositoryName(name)
        }
    }

    private func run(
        _ arguments: [String],
        at directoryURL: URL? = nil,
        maximumOutputBytes: Int = 4 * 1_024 * 1_024
    ) async throws -> GitHubCommandOutput {
        guard let executableURL else { throw GitHubCLIError.notInstalled }
        try Task.checkCancellation()

        let fileManager = FileManager.default
        let captureDirectory = fileManager.temporaryDirectory.appending(
            path: "rafu-gh-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: captureDirectory) }

        let outputURL = captureDirectory.appending(path: "stdout")
        let errorURL = captureDirectory.appending(path: "stderr")
        guard fileManager.createFile(atPath: outputURL.path, contents: nil),
            fileManager.createFile(atPath: errorURL.path, contents: nil)
        else {
            throw GitHubCLIError.couldNotLaunch("Rafu could not create temporary output files.")
        }

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let directoryURL { process.currentDirectoryURL = directoryURL }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        // gh needs the user's real environment (HOME, GH_CONFIG_DIR,
        // GH_TOKEN, etc.) to find its auth state — unlike
        // `GitCommandRunner`, this is deliberately the full, unhardened
        // `ProcessInfo` environment rather than a stripped-down subset.
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
        } catch {
            throw GitHubCLIError.couldNotLaunch(error.localizedDescription)
        }

        do {
            while process.isRunning {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch is CancellationError {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw CancellationError()
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }

        try outputHandle.close()
        try errorHandle.close()
        try Task.checkCancellation()

        let stdoutSize = try fileSize(at: outputURL)
        let stderrSize = try fileSize(at: errorURL)
        guard stdoutSize <= maximumOutputBytes, stderrSize <= maximumOutputBytes else {
            throw GitHubCLIError.commandFailed(
                "GitHub CLI produced an unexpectedly large response.")
        }

        return GitHubCommandOutput(
            arguments: arguments,
            terminationStatus: process.terminationStatus,
            standardOutput: try Data(contentsOf: outputURL, options: .mappedIfSafe),
            standardError: try Data(contentsOf: errorURL, options: .mappedIfSafe)
        )
    }

    private func fileSize(at url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return values.fileSize ?? 0
    }

    private static func mapError(_ output: GitHubCommandOutput) -> GitHubCLIError {
        mapError(stderr: output.stderr, terminationStatus: output.terminationStatus)
    }

    /// Maps `gh`'s stderr text (plus its exit status, for the generic
    /// fallback message) to a `GitHubCLIError`. Pure and unit-testable
    /// against representative stderr strings without spawning `gh`.
    static func mapError(stderr: String, terminationStatus: Int32) -> GitHubCLIError {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = message.lowercased()
        if lowered.contains("gh auth login") || lowered.contains("not logged")
            || lowered.contains("authentication")
        {
            return .notAuthenticated
        }
        if lowered.contains("already exists") {
            return .remoteAlreadyExists
        }
        return .commandFailed(
            message.isEmpty
                ? "GitHub CLI command failed (\(terminationStatus))." : message
        )
    }
}
