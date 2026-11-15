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

    /// The title a Terminal Group shows on its editor tab, its Ensemble card
    /// and in the tab switcher. A name the user gave the group (or the card)
    /// wins. An automatic name ("Terminal Group 1", "Terminal") carries no
    /// information, so it gives way to the name the user gave the pane, then
    /// to the agent's title. Otherwise the stored name stays. The stored name
    /// itself never changes here.
    static func resolvedGroupTitle(
        storedName: String, paneUserName: String?, agentTitle: String?
    ) -> String {
        guard isAutomaticGroupName(storedName) else { return storedName }
        if let pane = paneUserName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !pane.isEmpty
        {
            return pane
        }
        if let agent = agentTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            !agent.isEmpty
        {
            return agent
        }
        return storedName
    }

    /// `resolvedGroupTitle` for a live group: the focused pane supplies the
    /// pane name (an Ensemble card's group has exactly one pane).
    static func resolvedGroupTitle(_ group: TerminalGroupSnapshot, agentTitle: String?) -> String {
        resolvedGroupTitle(
            storedName: group.name.rawValue,
            paneUserName: group.panes.first { $0.id == group.focusedPaneID }?
                .explicitUserName?.rawValue,
            agentTitle: agentTitle)
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

    /// The Terminals header count, spoken: "1 terminal", "3 terminals". A
    /// group and an ungrouped session each count as one terminal; "legacy"
    /// is an internal word and never reaches the user.
    static func terminalCountLabel(_ count: Int) -> String {
        count == 1 ? "1 terminal" : "\(count) terminals"
    }

    // MARK: Terminals panel rows ("tuned rows")

    /// A panel row's title: the most specific name, never repeated by the
    /// second line. A name the user gave the group wins, then the name the
    /// user gave the focused pane, then the agent's session title (or the
    /// agent's name for a generic title), then the shell or agent name. The
    /// folder is not part of the title; the second line carries it.
    static func panelTitle(
        storedGroupName: String?, paneUserName: String?, agentTitle: String?,
        providerOrShell: String
    ) -> String {
        let fallback = providerOrShell.trimmingCharacters(in: .whitespacesAndNewlines)
        return resolvedGroupTitle(
            storedName: storedGroupName ?? "Terminal",
            paneUserName: paneUserName,
            agentTitle: agentTitle ?? (fallback.isEmpty ? nil : fallback))
    }

    /// Adds an ordinal to the second and later rows that read the same: the
    /// same title and the same context line ("Claude Code", "Claude Code 2").
    /// Rows keep creation order. A name the user typed never changes.
    static func disambiguatedTitles(_ rows: [(title: String, context: String, isUserNamed: Bool)])
        -> [String]
    {
        var seen: [String: Int] = [:]
        return rows.map { row in
            guard !row.isUserNamed else { return row.title }
            let key = row.title + "\u{1F}" + row.context
            let count = (seen[key] ?? 0) + 1
            seen[key] = count
            return count == 1 ? row.title : "\(row.title) \(count)"
        }
    }

    /// The context line a row shows under its title: the agent or shell
    /// name (left out when the title already is that name) and the folder,
    /// or the pane count and folder for a group with more than one pane.
    static func panelContext(
        title: String, providerOrShell: String, folder: String?, paneCount: Int
    )
        -> String
    {
        if paneCount > 1 { return subtitle([paneCountLabel(paneCount), folder ?? ""]) }
        let sameAsTitle =
            providerOrShell.trimmingCharacters(in: .whitespaces).lowercased()
            == title.trimmingCharacters(in: .whitespaces).lowercased()
        return subtitle([sameAsTitle ? "" : providerOrShell, folder ?? ""])
    }

    /// The full second line: an abnormal status word first, then the
    /// context, then where the terminal lives ("Ensemble", "Hidden").
    static func panelSubtitle(statusWord: String?, context: String, placement: String?) -> String {
        subtitle([statusWord ?? "", context, placement ?? ""])
    }

    /// "Ensemble" for a group whose card is on an Ensemble board, "Hidden" for
    /// a group with no tab, else `nil`. Never "Canvas" or "Parked".
    static func panelPlacement(isCanvasOwned: Bool, isParked: Bool) -> String? {
        if isCanvasOwned { return "Ensemble" }
        return isParked ? "Hidden" : nil
    }

    /// The status word a row shows, or `nil` in the normal state. A running
    /// or idle shell and a working, done, or inactive agent are normal: the
    /// glyph says so. Attention, a failure, an exit, a stop, or an
    /// unavailable pane leads the second line as a word, so the state never
    /// depends on the glyph's colour or shape alone.
    static func abnormalStatusWord(
        agentStatus: AgentCardStatus?, paneStatus: TerminalPaneStatus, hasAttention: Bool
    ) -> String? {
        if let agentStatus {
            switch agentStatus {
            case .needsYou, .failed, .stopped: return agentStatus.word
            case .working, .done, .doneUnread, .inactive:
                return hasAttention ? "Needs attention" : nil
            }
        }
        if hasAttention { return "Needs attention" }
        switch paneStatus {
        case .idle, .live: return nil
        case .exited: return "Exited"
        case .stopped: return "Stopped"
        case .unavailable: return "Unavailable"
        }
    }

    /// The status word of an ungrouped session row, or `nil` while it runs
    /// or is idle: "Needs attention", "Exited (1)".
    static func abnormalSessionStatusWord(_ status: TerminalSessionStatus) -> String? {
        switch status {
        case .idle, .running: nil
        case .bell, .exited: TerminalSessionPresentation.label(status)
        }
    }

    /// The status word of a group with more than one pane: attention, else
    /// "Not running" when no pane runs, else `nil`.
    static func abnormalGroupStatusWord(attentionCount: Int, livePaneCount: Int) -> String? {
        if attentionCount > 0 { return attentionLabel(attentionCount) }
        return livePaneCount == 0 ? groupStateLabel(livePaneCount: 0) : nil
    }

    /// A shape-distinct SF Symbol for a shell's state in the 16 pt status
    /// slot (an agent uses `AgentActivityGlyph`). Attention is a bell.
    static func shellStatusSymbol(paneStatus: TerminalPaneStatus, hasAttention: Bool) -> String {
        if hasAttention { return "bell.fill" }
        return switch paneStatus {
        case .idle: "circle"
        case .live: "circle.fill"
        case .exited: "xmark.circle.fill"
        case .stopped: "stop.circle"
        case .unavailable: "exclamationmark.triangle"
        }
    }

    /// A pane row's name: the user's name, then a meaningful reported title
    /// (not a path, the shell, or the agent's bare name), then the shell or
    /// agent name. The ordinal beside it tells identical panes apart.
    static func paneRowTitle(
        userName: String?, reportedTitle: String?, providerOrShell: String,
        shellName: String?, provider: ConductorCLIID?
    ) -> String {
        if let userName = userName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !userName.isEmpty
        {
            return userName
        }
        if let reportedTitle,
            !TerminalSessionPresentation.isGenericTitle(
                reportedTitle, shellName: shellName, provider: provider)
        {
            return reportedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return providerOrShell
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

    /// Menu title for a shell: its name, with " (default)" after it for the
    /// default shell. Two shells with the same name (for example `/bin/zsh`
    /// and a Homebrew `zsh`) get their path appended so the menu items can
    /// be told apart.
    static func shellMenuTitle(for shell: TerminalShell, among shells: [TerminalShell]) -> String {
        let title = shell.isDefault ? shell.name + defaultShellSuffix : shell.name
        let duplicates = shells.count { $0.name == shell.name } > 1
        return duplicates ? title + separator + shell.path : title
    }

    /// The marker after the default shell's name in a menu title. A tile that
    /// cannot fit it shows `shellChipName` and a separate marker.
    static let defaultShellSuffix = " (default)"

    /// The shell name for a tile that shows the default marker on its own:
    /// the name, with the path appended only for a same-named shell.
    static func shellChipName(for shell: TerminalShell, among shells: [TerminalShell]) -> String {
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
