import Foundation
import RafuCore

/// One Ensemble terminal node that resumes an agent session: its name, its
/// workspace-relative starting folder, and the POSIX-quoted resume line.
nonisolated struct AgentHistoryEnsembleResumePlan: Equatable, Sendable {
    let key: AgentHistorySessionKey
    let title: String
    let startingFolder: TerminalWorkspaceRelativePath
    let line: String
}

/// How Rafu starts `claude --resume <id>` and `codex resume <id>`.
///
/// Resume in Terminal does not type into a shell. It starts the CLI itself
/// as the terminal's process (an Agent Terminal), with the argument array
/// from `AgentHistoryResumeCommand` and the session's folder as the working
/// directory. Resume in Ensemble adds a terminal node whose shell receives
/// the same arguments as one quoted line, so the agent joins the Ensemble
/// bridge like every agent that starts in an Ensemble terminal.
nonisolated enum AgentHistoryResumeLaunch {
    /// The resume arguments without the program name, or `nil` when the
    /// session id is not safe (see `AgentHistoryResumeCommand`).
    static func processArguments(for key: AgentHistorySessionKey) -> [String]? {
        guard let arguments = AgentHistoryResumeCommand.arguments(for: key) else { return nil }
        return Array(arguments.dropFirst())
    }

    /// The command a person can type in a shell, for messages.
    static func commandLine(for key: AgentHistorySessionKey) -> String? {
        AgentHistoryResumeCommand.arguments(for: key).map(AgentHistoryResumeCommand.shellLine)
    }

    /// The Agent Terminal process for a resume. `executableURL` is the
    /// absolute path the provider's adapter found. The child gets the same
    /// one-key environment as every Agent Terminal: the curated `PATH`, with
    /// the executable's own folder first.
    static func specification(
        for key: AgentHistorySessionKey, executableURL: URL, folder: URL
    ) -> TerminalProcessSpec? {
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/"),
            let arguments = processArguments(for: key)
        else { return nil }
        let cli = key.provider.cli
        return TerminalProcessSpec(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryPath: folder.standardizedFileURL.path,
            environment: [
                RafuConductorEnvironment.path: childSearchPath(prependingParentOf: executableURL)
            ],
            roleBadge: cli.displayName,
            resourceAttribution: "\(cli.displayName) (agent terminal)",
            agentProvider: cli
        )
    }

    /// Shown when the provider's CLI is not installed or not found.
    static func missingCLIMessage(for key: AgentHistorySessionKey, folderName: String) -> String {
        let name = key.provider.displayName
        guard let line = commandLine(for: key) else {
            return "Rafu cannot find the \(name) command-line tool."
        }
        return
            "Rafu cannot find the \(name) command-line tool. Install it, or open a terminal in “\(folderName)” and run: \(line)"
    }

    /// The curated search path with the executable's folder first, once.
    static func childSearchPath(
        prependingParentOf executableURL: URL,
        curated: String = RafuConductorEnvironment.curatedPath
    ) -> String {
        let folder = executableURL.deletingLastPathComponent().standardizedFileURL.path
        guard !curated.split(separator: ":").contains(Substring(folder)) else { return curated }
        return "\(folder):\(curated)"
    }

    /// The Ensemble node for a resume. `folder` must be at or below
    /// `workspaceRoot` after symbolic links resolve; otherwise `nil`.
    static func ensemblePlan(
        for key: AgentHistorySessionKey, sessionTitle: String, folder: URL, workspaceRoot: URL
    ) -> AgentHistoryEnsembleResumePlan? {
        guard let line = commandLine(for: key),
            let relative = relativeFolder(folder, inside: workspaceRoot),
            let startingFolder = TerminalWorkspaceRelativePath(relative)
        else { return nil }
        return AgentHistoryEnsembleResumePlan(
            key: key, title: nodeTitle(sessionTitle, provider: key.provider),
            startingFolder: startingFolder, line: line)
    }

    /// The session title on one line, at most 72 characters; the provider
    /// name when the title is empty. Fits `TerminalGroupName` and the
    /// Ensemble card-title limit.
    static func nodeTitle(_ sessionTitle: String, provider: AgentHistoryProvider) -> String {
        let words = sessionTitle.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let joined = words.joined(separator: " ")
        guard !joined.isEmpty else { return provider.displayName }
        guard joined.count > 72 else { return joined }
        return String(joined.prefix(71)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// `folder` relative to `root` ("" for the root itself), or `nil` when it
    /// is outside.
    static func relativeFolder(_ folder: URL, inside root: URL) -> String? {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
        if path == rootPath { return "" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}
