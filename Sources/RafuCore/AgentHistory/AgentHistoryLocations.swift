import Foundation

/// Where each agent CLI keeps its transcripts. Resolution follows the CLIs:
/// Claude Code honours `CLAUDE_CONFIG_DIR`, Codex honours `CODEX_HOME`.
///
/// A GUI app opened from Finder or the Dock usually does not inherit the
/// variables a login shell sets, so Settings shows the resolved folders.
public struct AgentHistoryLocations: Equatable, Sendable {
    /// `<config>/projects`, one folder per working directory.
    public let claudeProjectsDirectory: URL
    /// `<codex home>`.
    public let codexHomeDirectory: URL

    public var codexSessionsDirectory: URL {
        codexHomeDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Append-only `{"id", "thread_name", ...}` rows; the last row wins.
    public var codexSessionIndexFile: URL {
        codexHomeDirectory.appendingPathComponent("session_index.jsonl", isDirectory: false)
    }

    public init(claudeProjectsDirectory: URL, codexHomeDirectory: URL) {
        self.claudeProjectsDirectory = claudeProjectsDirectory
        self.codexHomeDirectory = codexHomeDirectory
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AgentHistoryLocations {
        let claudeConfig =
            directory(from: environment["CLAUDE_CONFIG_DIR"], home: homeDirectory)
            ?? homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        let codexHome =
            directory(from: environment["CODEX_HOME"], home: homeDirectory)
            ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        return AgentHistoryLocations(
            claudeProjectsDirectory: claudeConfig.appendingPathComponent(
                "projects", isDirectory: true),
            codexHomeDirectory: codexHome)
    }

    /// Accepts an absolute path or `~/…`. Anything else (empty, relative,
    /// or a list) is ignored and the default folder is used.
    private static func directory(from value: String?, home: URL) -> URL? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return nil }
        if value == "~" {
            return home
        }
        if value.hasPrefix("~/") {
            value = home.path + "/" + value.dropFirst(2)
        }
        guard value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: AgentHistoryPath.normalized(value), isDirectory: true)
    }
}
