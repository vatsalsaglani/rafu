import SwiftUI

// The one place Rafu decides "which agent CLI is this?" and "how is its mark
// drawn?". Every surface that shows an agent (editor tabs, the Terminals
// panel, the command palette, the status bar, Ensemble node headers, the
// notch) goes through `ConductorCLIID.detect` and `AgentIconView`, so a
// manually typed `claude` and a Rafu-launched Claude Code terminal look the
// same everywhere.

extension ConductorCLIID {
    /// Maps the first word of a command line, or of a terminal title, to an
    /// agent CLI. Returns `nil` for shells and anything unrecognised.
    ///
    /// - The command is checked first: leading `NAME=value` assignments are
    ///   skipped, a path is reduced to its last component
    ///   (`/opt/bin/claude` is `claude`), and surrounding quotes are removed.
    /// - The title is checked second. Agent CLIs prefix their title with a
    ///   status glyph ("✳ claude", "⠂ codex"), so leading symbols are skipped.
    ///   A few two-word product names ("Claude Code", "OpenAI Codex") are
    ///   matched as phrases.
    nonisolated static func detect(command: String?, title: String?) -> ConductorCLIID? {
        if let command, let found = AgentIdentityMatcher.match(command: command) {
            return found
        }
        if let title, let found = AgentIdentityMatcher.match(title: title) {
            return found
        }
        return nil
    }

    /// SF Symbol for places that cannot draw the vendor SVG. Vendor SVGs
    /// render 1 x 1 pt inside an `NSMenu` (SwiftUI `Menu`, context menus), so
    /// menu items must use this symbol instead of `AgentIconView`.
    nonisolated var menuFallbackSymbolName: String { "terminal" }
}

/// Pure matching rules, kept separate so the tests can pin every alias.
nonisolated enum AgentIdentityMatcher {
    /// One word (already lowercased, path-stripped) to its CLI.
    private static let words: [String: ConductorCLIID] = [
        "claude": .claudeCode,
        "claude-code": .claudeCode,
        "codex": .codex,
        "codex-cli": .codex,
        "opencode": .openCode,
        "gemini": .geminiCLI,
        "gemini-cli": .geminiCLI,
        "cursor-agent": .cursor,
        "cursor": .cursor,
        "kimi": .kimi,
        "kimi-cli": .kimi,
        "cline": .cline,
    ]

    /// Two-word product names that appear as terminal titles.
    private static let phrases: [(prefix: String, cli: ConductorCLIID)] = [
        ("claude code", .claudeCode),
        ("openai codex", .codex),
        ("open code", .openCode),
        ("gemini cli", .geminiCLI),
        ("cursor agent", .cursor),
        ("cursor cli", .cursor),
        ("kimi cli", .kimi),
    ]

    static func match(command: String) -> ConductorCLIID? {
        for token in command.split(whereSeparator: \.isWhitespace) {
            // `FOO=bar claude` runs claude with an environment variable.
            if isEnvironmentAssignment(token) { continue }
            return words[normalizedWord(String(token))]
        }
        return nil
    }

    static func match(title: String) -> ConductorCLIID? {
        let lowered = title.lowercased()
        let trimmed = String(lowered.drop(while: { !$0.isLetter && !$0.isNumber }))
        guard !trimmed.isEmpty else { return nil }
        for (prefix, cli) in phrases where hasWordPrefix(trimmed, prefix) {
            return cli
        }
        guard let first = trimmed.split(whereSeparator: \.isWhitespace).first else { return nil }
        return words[normalizedWord(String(first))]
    }

    private static func isEnvironmentAssignment(_ token: Substring) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else {
            return false
        }
        return token[token.startIndex..<equals].allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "_"
        }
    }

    /// Lowercase, strip quotes and trailing punctuation, keep the last path
    /// component. `"/usr/local/bin/Claude"` becomes `claude`.
    private static func normalizedWord(_ raw: String) -> String {
        var word = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        if let slash = word.lastIndex(of: "/") {
            word = String(word[word.index(after: slash)...])
        }
        return word.trimmingCharacters(in: CharacterSet(charactersIn: ":,;.—–-"))
    }

    /// `text` starts with `prefix` and the next character (if any) is not part
    /// of the same word.
    private static func hasWordPrefix(_ text: String, _ prefix: String) -> Bool {
        guard text.hasPrefix(prefix) else { return false }
        let rest = text.dropFirst(prefix.count)
        guard let next = rest.first else { return true }
        return !(next.isLetter || next.isNumber)
    }
}

/// Surfaces that list terminals ask these properties, not `agentProvider`
/// alone: `agentProvider` is set only for a terminal Rafu launched as an
/// agent. A user who types `claude` in a login shell is just as much an
/// agent session, and its terminal title ("✳ claude") says so.
extension WorkspaceTerminalController {
    var resolvedAgentProvider: ConductorCLIID? {
        agentProvider ?? ConductorCLIID.detect(command: nil, title: displayName)
    }
}

extension AgentActivitySummary {
    /// Counts the agent sessions among `sessions`: a terminal Rafu launched
    /// as an agent, or one whose title names an agent CLI, with a live process.
    init(sessions: [WorkspaceTerminalController]) {
        self.init(
            entries: sessions.map { controller in
                Entry(
                    provider: controller.resolvedAgentProvider,
                    isLive: controller.hasLiveProcess,
                    needsAttention: TerminalSessionPresentation.needsAttention(controller.status))
            })
    }
}

extension TerminalSessionRow {
    nonisolated var resolvedAgentProvider: ConductorCLIID? {
        agentProvider ?? ConductorCLIID.detect(command: nil, title: displayName)
    }
}

/// The vendor mark for one agent CLI, drawn from `ConductorCLIIcons` (the
/// template-tinted bundled SVG with a system-symbol fallback). SwiftUI views
/// and popovers only: inside an `NSMenu` the SVG renders 1 x 1 pt, so menu
/// items use `ConductorCLIID.menuFallbackSymbolName` instead.
struct AgentIconView: View {
    let cli: ConductorCLIID
    var size: CGFloat = 16

    var body: some View {
        FileIconView(icon: ConductorCLIIcons.icon(for: cli), size: size)
            .frame(width: size, height: size)
            .accessibilityLabel(cli.displayName)
    }
}
