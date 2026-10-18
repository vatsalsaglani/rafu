import Foundation

/// Pure naming and wording helpers for the Terminals panel (macOS redesign
/// T2, T8). No SwiftUI and no filesystem access, so everything here is
/// headless-testable and safe to call from a view body.
nonisolated enum TerminalNaming {
    /// Separator between the command and the folder in an automatic name.
    static let separator = " — "

    /// `true` for the names Rafu generates itself ("Terminal Group 3" and the
    /// Canvas placeholder "Terminal"). Such a name carries no information, so
    /// the panel shows an automatic name built from the pane instead. A name
    /// the user typed is never replaced.
    static func isAutomaticGroupName(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "Terminal" { return true }
        let prefix = "Terminal Group "
        guard trimmed.hasPrefix(prefix) else { return false }
        let rest = trimmed.dropFirst(prefix.count)
        return !rest.isEmpty && rest.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The last folder component to show in a name. A nil, empty, or "."
    /// path means the workspace root, so the root's own folder name is used.
    static func folderName(
        path: String?,
        workspaceRoot: String?,
        homeDirectory: String = NSHomeDirectory()
    ) -> String? {
        let root = normalizedPath(workspaceRoot)
        guard let path = normalizedPath(path), path != "." else {
            return lastComponent(of: root)
        }
        if path == "/" { return "/" }
        if path == normalizedPath(homeDirectory) { return "~" }
        return lastComponent(of: path)
    }

    /// "zsh — fixtures" for a command and a folder; the bare command when no
    /// folder is known.
    static func automaticName(command: String, folder: String?) -> String {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let folder, !folder.isEmpty else { return trimmedCommand }
        guard !trimmedCommand.isEmpty else { return folder }
        return trimmedCommand + separator + folder
    }

    /// "1 pane", "2 panes".
    static func paneCountLabel(_ count: Int) -> String {
        count == 1 ? "1 pane" : "\(count) panes"
    }

    /// The group state word. A group is "Running" while any pane has a live
    /// process; otherwise "Not running". Never "Parked".
    static func groupStateLabel(livePaneCount: Int) -> String {
        livePaneCount > 0 ? "Running" : "Not running"
    }

    /// "1 needs attention", "2 need attention".
    static func attentionLabel(_ count: Int) -> String {
        count == 1 ? "1 needs attention" : "\(count) need attention"
    }

    /// The group row's second line: "2 panes · Running", plus attention.
    static func groupSummary(paneCount: Int, livePaneCount: Int, attentionCount: Int) -> String {
        var parts = [
            paneCountLabel(paneCount),
            groupStateLabel(livePaneCount: livePaneCount),
        ]
        if attentionCount > 0 { parts.append(attentionLabel(attentionCount)) }
        return parts.joined(separator: " · ")
    }

    /// Joins subtitle parts with " · " and drops empty parts and a bare "."
    /// (the workspace root), so a subtitle never ends in a dangling separator.
    static func subtitle(_ parts: [String]) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." }
            .joined(separator: " · ")
    }

    /// Menu title for a shell. Two shells with the same name (for example
    /// `/bin/zsh` and a Homebrew `zsh`) get their path appended so the menu
    /// items can be told apart.
    static func shellMenuTitle(for shell: TerminalShell, among shells: [TerminalShell]) -> String {
        let duplicates = shells.count { $0.name == shell.name } > 1
        return duplicates ? shell.name + separator + shell.path : shell.name
    }

    private static func normalizedPath(_ value: String?) -> String? {
        guard var path = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty
        else { return nil }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func lastComponent(of path: String?) -> String? {
        guard let path else { return nil }
        let component = (path as NSString).lastPathComponent
        return component.isEmpty ? nil : component
    }
}
