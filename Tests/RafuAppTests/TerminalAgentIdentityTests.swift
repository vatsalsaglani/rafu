import Foundation
import Testing

@testable import RafuApp

/// A shell where the person typed `claude` or `codex` keeps the agent's
/// identity while the agent runs, even after the agent replaces its title,
/// and loses it when the shell is in front again or the process exits.
@Suite("Terminal agent identity")
struct TerminalAgentIdentityTests {
    // MARK: - Resolution order

    @Test("Launched beats hook beats foreground beats sticky title beats current title")
    func resolutionOrder() {
        let foreground = TerminalAgentIdentityState(
            foreground: .agent(.codex), stickyTitleProvider: .geminiCLI)
        #expect(
            TerminalAgentResolution.resolve(
                launched: .claudeCode, hook: .cursor, observed: foreground,
                currentTitle: "opencode") == .claudeCode)
        #expect(
            TerminalAgentResolution.resolve(
                launched: nil, hook: .cursor, observed: foreground, currentTitle: "opencode")
                == .cursor)
        #expect(
            TerminalAgentResolution.resolve(
                launched: nil, hook: nil, observed: foreground, currentTitle: "opencode")
                == .codex)

        let sticky = TerminalAgentIdentityState(foreground: .other, stickyTitleProvider: .geminiCLI)
        #expect(
            TerminalAgentResolution.resolve(
                launched: nil, hook: nil, observed: sticky, currentTitle: "opencode")
                == .geminiCLI)

        let unknown = TerminalAgentIdentityState()
        #expect(
            TerminalAgentResolution.resolve(
                launched: nil, hook: nil, observed: unknown, currentTitle: "opencode")
                == .openCode)
        #expect(
            TerminalAgentResolution.resolve(
                launched: nil, hook: nil, observed: unknown, currentTitle: "zsh 1") == nil)
    }

    @Test("A shell in front hides a stale agent title")
    func shellForegroundHidesStaleTitle() {
        let state = TerminalAgentIdentityState(foreground: .shell)
        #expect(state.provider(currentTitle: "claude") == nil)
    }

    // MARK: - Sticky title

    @Test("A task title keeps the agent the earlier title named")
    func stickyTitleSurvivesTitleChange() {
        var state = TerminalAgentIdentityState()
        state.noteTitle("claude")
        state.noteTitle("✳ Fix tests")
        #expect(state.stickyTitleProvider == .claudeCode)
        #expect(state.provider(currentTitle: "✳ Fix tests") == .claudeCode)

        state.noteTitle(nil)
        #expect(state.provider(currentTitle: nil) == .claudeCode)
    }

    @Test("The shell in front again clears the sticky title")
    func shellForegroundClearsStickyTitle() {
        var state = TerminalAgentIdentityState()
        state.noteTitle("claude")
        state.noteForeground(.shell)
        #expect(state.stickyTitleProvider == nil)
        #expect(state.provider(currentTitle: "✳ Fix tests") == nil)
    }

    @Test("Another program in front keeps the sticky title; reset clears all")
    func otherForegroundKeepsStickyTitle() {
        var state = TerminalAgentIdentityState()
        state.noteTitle("⠂ codex")
        state.noteForeground(.other)
        #expect(state.provider(currentTitle: "working") == .codex)

        state.reset()
        #expect(state == TerminalAgentIdentityState())
        #expect(state.provider(currentTitle: "working") == nil)
    }

    @Test("A foreground agent wins over a different sticky title")
    func foregroundAgentWins() {
        var state = TerminalAgentIdentityState()
        state.noteTitle("claude")
        state.noteForeground(.agent(.codex))
        #expect(state.provider(currentTitle: "claude") == .codex)
    }

    // MARK: - Controller

    @MainActor
    @Test("A live shell keeps Claude through a task title and loses it at the prompt")
    func controllerStickyIdentity() throws {
        let session = WorkspaceSession()
        session.newTerminalTab()
        let controller = try #require(session.terminal.sessions.first)
        controller.markRunningForTesting()

        controller.updateTitle("claude")
        #expect(controller.resolvedAgentProvider == .claudeCode)
        #expect(controller.presentedTitle == "Claude Code")

        controller.updateTitle("✳ Fix tests")
        #expect(controller.resolvedAgentProvider == .claudeCode)
        #expect(controller.presentedTitle == "✳ Fix tests")

        controller.updateTitle("")
        #expect(controller.resolvedAgentProvider == .claudeCode)
        #expect(controller.presentedTitle == "Claude Code")

        controller.noteForeground(.shell)
        #expect(controller.resolvedAgentProvider == nil)
        #expect(controller.presentedTitle == controller.displayName)
    }

    @MainActor
    @Test("Process exit clears the observed identity")
    func controllerExitClearsIdentity() throws {
        let session = WorkspaceSession()
        session.newTerminalTab()
        let controller = try #require(session.terminal.sessions.first)
        controller.markRunningForTesting()
        controller.updateTitle("codex")
        controller.noteForeground(.agent(.codex))
        #expect(controller.resolvedAgentProvider == .codex)

        controller.processDidTerminate(exitCode: 0)
        #expect(controller.agentIdentity == TerminalAgentIdentityState())
        #expect(controller.resolvedAgentProvider == nil)
    }

    @MainActor
    @Test("Panel rows carry the controller's resolution")
    func rowsCarryControllerResolution() throws {
        let session = WorkspaceSession()
        session.newTerminalTab()
        let controller = try #require(session.terminal.sessions.first)
        controller.markRunningForTesting()
        controller.updateTitle("claude")
        controller.updateTitle("✳ Fix tests")

        let row = try #require(
            TerminalsPanelModel.rows(
                sessions: [controller], presentedIDs: [], workspaceRoot: nil
            ).first)
        #expect(row.isAgentIdentityResolved)
        #expect(row.resolvedAgentProvider == .claudeCode)
        #expect(row.presentedTitle == "✳ Fix tests")

        controller.noteForeground(.shell)
        let cleared = try #require(
            TerminalsPanelModel.rows(
                sessions: [controller], presentedIDs: [], workspaceRoot: nil
            ).first)
        #expect(cleared.resolvedAgentProvider == nil)
    }

    // MARK: - Title presentation

    @Test(
        "Generic titles become the agent's name",
        arguments: [
            "", "   ", "✳", "⠂⠄", "Terminal", "terminal", "Terminal Pane", "zsh", "-zsh",
            "zsh 3", "bash", "~/work/rafu", "/usr/local", "claude", "✳ claude", "Claude Code",
            "✳ Claude Code",
        ])
    func genericTitles(title: String) {
        #expect(
            TerminalSessionPresentation.title(
                displayName: title, hasUserName: false, provider: .claudeCode, shellName: "zsh")
                == "Claude Code")
    }

    @Test(
        "Meaningful titles stay",
        arguments: ["✳ Fix tests", "Refactor parser", "claude — ~/work/rafu", "vim notes.md"])
    func meaningfulTitles(title: String) {
        #expect(
            TerminalSessionPresentation.title(
                displayName: title, hasUserName: false, provider: .claudeCode, shellName: "zsh")
                == title)
    }

    @Test("A user name and a terminal without an agent keep their name")
    func userNameAndNoAgent() {
        #expect(
            TerminalSessionPresentation.title(
                displayName: "zsh", hasUserName: true, provider: .codex, shellName: "zsh") == "zsh")
        #expect(
            TerminalSessionPresentation.title(
                displayName: "zsh 2", hasUserName: false, provider: nil, shellName: "zsh")
                == "zsh 2")
    }

    @Test("Codex names itself for a generic title")
    func codexGenericTitle() {
        #expect(
            TerminalSessionPresentation.title(
                displayName: "codex", hasUserName: false, provider: .codex, shellName: "zsh")
                == "Codex")
        #expect(
            TerminalSessionPresentation.agentTitle(
                reportedTitle: nil, provider: .codex, shellName: nil) == "Codex")
        #expect(
            TerminalSessionPresentation.agentTitle(
                reportedTitle: "Review diff", provider: .codex, shellName: nil) == "Review diff")
    }

    // MARK: - Clean agent titles

    @Test(
        "cleanAgentTitle drops status badges, the prepared thread name, and paths",
        arguments: [
            ("[ ! ] Action Required | Rafu terminal | rafu", "rafu"),
            ("[ ! ] Action Required | Rafu terminal", "Codex"),
            ("[ ] Working | Rafu terminal | Fix login bug", "Fix login bug"),
            ("[ ! ] Action Required | Rafu terminal | ~/work/rafu", "Codex"),
            ("Ready | Rafu terminal", "Codex"),
            ("[!] Done | rafu | Rafu terminal", "rafu"),
            ("Waiting | rafu | Fix tests", "rafu | Fix tests"),
            ("[ ! ] Fix tests | Rafu terminal", "Fix tests"),
            ("Rafu terminal", "Codex"),
            ("", "Codex"),
            ("✳ Rafu orb redesign", "✳ Rafu orb redesign"),
            ("Refactor parser", "Refactor parser"),
        ])
    func cleanCodexTitle(raw: String, expected: String) {
        #expect(TerminalSessionPresentation.cleanAgentTitle(raw, provider: .codex) == expected)
    }

    @Test("cleanAgentTitle falls back to the provider's own name")
    func cleanTitleFallsBackToProviderName() {
        #expect(
            TerminalSessionPresentation.cleanAgentTitle(
                "[ ! ] Action Required | Rafu terminal", provider: .claudeCode) == "Claude Code")
        #expect(
            TerminalSessionPresentation.cleanAgentTitle(
                "[ ] | /tmp | ~/work/rafu", provider: .codex)
                == "Codex")
    }

    @Test("Codex and Claude titles are cleaned where the terminal name is built")
    func cleanedTitlesReachTheTerminalName() {
        #expect(
            TerminalSessionPresentation.title(
                displayName: "[ ! ] Action Required | Rafu terminal | rafu", hasUserName: false,
                provider: .codex, shellName: "zsh") == "rafu")
        #expect(
            TerminalSessionPresentation.title(
                displayName: "[ ! ] Action Required | Rafu terminal", hasUserName: false,
                provider: .codex, shellName: "zsh") == "Codex")
        #expect(
            TerminalSessionPresentation.title(
                displayName: "✳ Rafu orb redesign", hasUserName: false, provider: .claudeCode,
                shellName: "zsh") == "✳ Rafu orb redesign")
        #expect(
            TerminalSessionPresentation.agentTitle(
                reportedTitle: "[ ] Working | Rafu terminal | Review diff", provider: .codex,
                shellName: "zsh") == "Review diff")
        #expect(
            TerminalSessionPresentation.agentTitle(
                reportedTitle: "[ ! ] Action Required | Rafu terminal", provider: .codex,
                shellName: nil) == "Codex")
    }

    @Test("A user name and another agent keep their title")
    func userNameAndOtherAgentsAreNotCleaned() {
        let raw = "[ ! ] Action Required | Rafu terminal"
        #expect(
            TerminalSessionPresentation.title(
                displayName: raw, hasUserName: true, provider: .codex, shellName: "zsh") == raw)
        #expect(
            TerminalSessionPresentation.title(
                displayName: raw, hasUserName: false, provider: .geminiCLI, shellName: "zsh")
                == raw)
    }

    // MARK: - Process mapping

    @Test(
        "Foreground processes map to agent CLIs",
        arguments: [
            (TerminalProcessDescription(name: "claude"), ConductorCLIID.claudeCode),
            (
                TerminalProcessDescription(
                    name: "2.0.14", executablePath: "/Users/me/.local/share/claude/versions/2.0.14",
                    arguments: ["claude"]),
                .claudeCode
            ),
            (TerminalProcessDescription(name: "codex"), .codex),
            (
                TerminalProcessDescription(
                    name: "node", executablePath: "/opt/homebrew/bin/node",
                    arguments: [
                        "node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                        "--resume",
                    ]),
                .claudeCode
            ),
            (
                TerminalProcessDescription(
                    name: "node",
                    arguments: [
                        "node", "--no-warnings",
                        "/usr/local/lib/node_modules/@openai/codex/bin/codex.js",
                    ]),
                .codex
            ),
            (
                TerminalProcessDescription(
                    name: "node", arguments: ["node", "/opt/homebrew/bin/claude"]),
                .claudeCode
            ),
            (TerminalProcessDescription(name: "opencode"), .openCode),
            (TerminalProcessDescription(name: "gemini"), .geminiCLI),
            (
                TerminalProcessDescription(
                    name: "node",
                    arguments: ["node", "/x/node_modules/@google/gemini-cli/dist/index.js"]),
                .geminiCLI
            ),
            (TerminalProcessDescription(name: "cursor-agent"), .cursor),
            (
                TerminalProcessDescription(
                    name: "node",
                    arguments: [
                        "node", "/Users/me/.local/share/cursor-agent/versions/1/index.js",
                    ]),
                .cursor
            ),
            (
                TerminalProcessDescription(
                    name: "bash", arguments: ["bash", "-c", "claude -p hi"]),
                .claudeCode
            ),
            (
                TerminalProcessDescription(name: "env", arguments: ["env", "FOO=1", "codex"]),
                .codex
            ),
        ])
    func processMapping(description: TerminalProcessDescription, expected: ConductorCLIID) {
        #expect(TerminalForegroundClassifier.classify(description) == .agent(expected))
    }

    @Test(
        "Shells in front are the shell",
        arguments: [
            TerminalProcessDescription(name: "zsh", arguments: ["-zsh"]),
            TerminalProcessDescription(name: "bash", executablePath: "/bin/bash"),
            TerminalProcessDescription(name: "fish", arguments: ["fish", "-l"]),
            TerminalProcessDescription(name: "-zsh"),
        ])
    func shellsAreShell(description: TerminalProcessDescription) {
        #expect(TerminalForegroundClassifier.classify(description) == .shell)
    }

    @Test(
        "Other programs are neither shell nor agent",
        arguments: [
            TerminalProcessDescription(name: "vim", arguments: ["vim", "notes.md"]),
            TerminalProcessDescription(name: "node", arguments: ["node", "server.js"]),
            TerminalProcessDescription(name: "bash", arguments: ["bash", "build.sh"]),
            TerminalProcessDescription(name: "swift", arguments: ["swift", "build"]),
            TerminalProcessDescription(name: "node", arguments: ["node"]),
        ])
    func othersAreOther(description: TerminalProcessDescription) {
        #expect(TerminalForegroundClassifier.classify(description) == .other)
    }

    @Test("An unreadable process is other")
    func unreadableIsOther() {
        #expect(TerminalForegroundClassifier.classify(nil) == .other)
    }

    // MARK: - argv parsing

    @Test("KERN_PROCARGS2 parsing reads argc argv entries, bounded, and no environment")
    func procargsParsing() {
        var bytes: [UInt8] = [3, 0, 0, 0]
        bytes += Array("/usr/bin/node".utf8) + [0, 0, 0]
        for word in ["node", "/x/cli.js", "--flag"] { bytes += Array(word.utf8) + [0] }
        bytes += Array("SECRET=1".utf8) + [0]

        #expect(
            TerminalProcessArguments.parse(bytes[...]) == ["node", "/x/cli.js", "--flag"])
        #expect(TerminalProcessArguments.parse(bytes[...], limit: 2) == ["node", "/x/cli.js"])
        #expect(TerminalProcessArguments.parse([UInt8]()[...]).isEmpty)
        #expect(TerminalProcessArguments.parse([0, 0, 0, 0, 1][...]).isEmpty)
    }

    // MARK: - Sampling policy

    @Test("The slow tick runs only while a non-shell program is in front and active")
    func pollingPolicy() {
        #expect(
            !TerminalForegroundSampling.continuesPolling(
                after: .shell, isVisible: true, secondsSinceOutput: 0))
        #expect(
            TerminalForegroundSampling.continuesPolling(
                after: .agent(.claudeCode), isVisible: true, secondsSinceOutput: nil))
        #expect(
            TerminalForegroundSampling.continuesPolling(
                after: .other, isVisible: false, secondsSinceOutput: 5))
        #expect(
            !TerminalForegroundSampling.continuesPolling(
                after: .agent(.codex), isVisible: false, secondsSinceOutput: 120))
        #expect(
            !TerminalForegroundSampling.continuesPolling(
                after: .agent(.codex), isVisible: false, secondsSinceOutput: nil))
    }
}
