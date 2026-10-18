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

    /// `true` when `text` is nothing but a name of `cli` ("claude",
    /// "claude code", "codex-cli"). Case and leading glyphs are ignored.
    static func isBareName(_ text: String, of cli: ConductorCLIID) -> Bool {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(lowered.drop(while: { !$0.isLetter && !$0.isNumber }))
        guard !trimmed.isEmpty else { return false }
        if trimmed == cli.displayName.lowercased() { return true }
        if phrases.contains(where: { $0.prefix == trimmed && $0.cli == cli }) { return true }
        guard !trimmed.contains(where: \.isWhitespace) else { return false }
        return words[normalizedWord(trimmed)] == cli
    }

    /// Interpreters and launchers that run an agent CLI as a script
    /// (`node …/@openai/codex/bin/codex.js`, `bun x claude`, a `bash`
    /// wrapper). For these, the first operand names the agent.
    private static let interpreters: Set<String> = [
        "node", "nodejs", "bun", "deno", "tsx", "python", "python3", "ruby", "env",
        "sh", "bash", "zsh", "dash",
    ]

    /// Script extensions removed before the stem is matched (`codex.js`).
    private static let scriptExtensions: Set<String> = [
        "js", "mjs", "cjs", "ts", "mts", "py", "sh",
    ]

    /// A foreground process (name, executable path, leading argv) to its
    /// CLI. Checks, in order: the process name, the executable's file name,
    /// `argv[0]`, then, for an interpreter, its first operand: the script's
    /// stem, the package directory after `node_modules`, or a hyphenated
    /// product directory (`claude-code`, `gemini-cli`) anywhere in the path.
    static func match(
        processName: String, executablePath: String?, arguments: [String]
    ) -> ConductorCLIID? {
        let executableName = executablePath.map(lastPathComponent)
        let argumentZero = arguments.first.map(lastPathComponent)
        for candidate in [processName, executableName, argumentZero].compactMap(\.self) {
            if let found = words[normalizedProcessWord(candidate)] { return found }
        }
        let launcherNames = [processName, executableName, argumentZero].compactMap(\.self)
            .map(normalizedProcessWord)
        guard launcherNames.contains(where: interpreters.contains),
            let operand = firstOperand(in: arguments)
        else { return nil }
        return match(scriptOperand: operand)
    }

    /// The first argv entry after `argv[0]` that is not a flag. `bash -c
    /// "claude --resume"` gives `claude --resume`; `node --no-warnings
    /// cli.js` gives `cli.js`; `env FOO=1 claude` gives `claude`. `nil`
    /// when there is none.
    static func firstOperand(in arguments: [String]) -> String? {
        arguments.dropFirst().first {
            !$0.isEmpty && !$0.hasPrefix("-") && !isEnvironmentAssignment(Substring($0))
        }
    }

    /// Lowercased, quotes and a leading login dash removed (`-zsh` is `zsh`).
    static func normalizedProcessWord(_ raw: String) -> String {
        normalizedWord(raw)
    }

    private static func match(scriptOperand operand: String) -> ConductorCLIID? {
        // A command string (`bash -c "claude --resume"`).
        if operand.contains(where: \.isWhitespace) {
            return match(command: operand)
        }
        let components = operand.split(separator: "/").map { String($0).lowercased() }
        guard let file = components.last else { return nil }
        if let found = words[normalizedWord(stem(of: file))] { return found }
        // `…/node_modules/@anthropic-ai/claude-code/cli.js`: the package.
        if let modules = components.lastIndex(of: "node_modules") {
            for component in components[(modules + 1)...] where !component.hasPrefix("@") {
                if let found = words[component] { return found }
                break
            }
        }
        // `~/.local/share/cursor-agent/versions/x/index.js`: a hyphenated
        // product name is specific enough to match anywhere in the path.
        for component in components.dropLast() where component.contains("-") {
            if let found = words[component] { return found }
        }
        return nil
    }

    private static func stem(of file: String) -> String {
        guard let dot = file.lastIndex(of: "."), dot != file.startIndex else { return file }
        let suffix = file[file.index(after: dot)...]
        return scriptExtensions.contains(String(suffix)) ? String(file[..<dot]) : file
    }

    private static func lastPathComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
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
/// agent session.
///
/// Resolution order (`TerminalAgentResolution`): the Rafu-launched provider,
/// then a live hook session matched to this terminal, then the foreground
/// process, then the sticky title match, then the current title. The
/// identity stays while the agent runs, even after it replaces its title,
/// and clears when the shell is in front again or the process exits.
extension WorkspaceTerminalController {
    var resolvedAgentProvider: ConductorCLIID? {
        TerminalAgentResolution.resolve(
            launched: agentProvider, hook: hookAgentProvider, observed: agentIdentity,
            currentTitle: identityTitle)
    }

    /// The identity without the hook signal. Hook matching itself uses this
    /// (`AgentActivityStore.candidate`), so the two never recurse.
    var observedAgentProvider: ConductorCLIID? {
        TerminalAgentResolution.resolve(
            launched: agentProvider, hook: nil, observed: agentIdentity,
            currentTitle: identityTitle)
    }

    /// The title fallback, only while the process has not exited: an exited
    /// shell whose last title still says "claude" runs no agent.
    private var identityTitle: String? {
        TerminalSessionPresentation.isExited(status) ? nil : displayName
    }

    /// The provider of a live hook session whose PID chain (or folder) puts
    /// it in this terminal; `nil` without hooks.
    private var hookAgentProvider: ConductorCLIID? {
        guard hasLiveProcess else { return nil }
        return AgentActivityStore.shared.trackedSession(for: self)?.provider.cli
    }

    /// The name every surface shows for this terminal: the agent's own name
    /// ("Claude Code") while the title is generic, otherwise the title.
    var presentedTitle: String {
        TerminalSessionPresentation.title(
            displayName: displayName, hasUserName: userName != nil,
            provider: resolvedAgentProvider, shellName: shellDisplayName)
    }
}

extension AgentActivitySummary {
    /// Counts the agent sessions among `sessions`: a terminal Rafu launched
    /// as an agent, or one that runs an agent CLI (`resolvedAgentProvider`),
    /// with a live process.
    /// Attention prefers hook state (`AgentActivityStore`: approval or an
    /// answer pending) and keeps the terminal's own bell as the fallback.
    init(sessions: [WorkspaceTerminalController], tracking: AgentActivityStore = .shared) {
        self.init(
            entries: sessions.map { controller in
                Entry(
                    provider: controller.resolvedAgentProvider,
                    isLive: controller.hasLiveProcess,
                    needsAttention: tracking.needsAttention(controller)
                        || TerminalSessionPresentation.needsAttention(controller.status))
            })
    }
}

extension TerminalSessionRow {
    /// A row built from a controller carries the controller's full
    /// resolution (`detectedAgentProvider`). A row built by hand falls back
    /// to its title.
    nonisolated var resolvedAgentProvider: ConductorCLIID? {
        if let agentProvider { return agentProvider }
        if isAgentIdentityResolved { return detectedAgentProvider }
        return ConductorCLIID.detect(command: nil, title: displayName)
    }

    /// The agent-aware name (`TerminalSessionPresentation.title`).
    nonisolated var presentedTitle: String {
        TerminalSessionPresentation.title(
            displayName: displayName, hasUserName: hasUserName,
            provider: resolvedAgentProvider, shellName: shellName)
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
