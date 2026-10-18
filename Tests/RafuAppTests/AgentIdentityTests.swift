import Testing

@testable import RafuApp

@Suite("Agent identity detection")
struct AgentIdentityTests {
    @Test(
        "The first word of a command names the agent",
        arguments: [
            ("claude", ConductorCLIID.claudeCode),
            ("claude --resume", .claudeCode),
            ("codex", .codex),
            ("codex exec \"fix it\"", .codex),
            ("opencode", .openCode),
            ("gemini", .geminiCLI),
            ("cursor-agent", .cursor),
            ("cursor", .cursor),
            ("kimi", .kimi),
            ("cline", .cline),
        ])
    func commandFirstWord(command: String, expected: ConductorCLIID) {
        #expect(ConductorCLIID.detect(command: command, title: nil) == expected)
    }

    @Test("A path is reduced to its last component, ignoring case and quotes")
    func commandPathInsensitive() {
        #expect(ConductorCLIID.detect(command: "/usr/local/bin/claude", title: nil) == .claudeCode)
        #expect(
            ConductorCLIID.detect(command: "~/.bun/bin/codex --full-auto", title: nil) == .codex)
        #expect(ConductorCLIID.detect(command: "\"/opt/bin/Gemini\"", title: nil) == .geminiCLI)
        #expect(ConductorCLIID.detect(command: "  claude  ", title: nil) == .claudeCode)
    }

    @Test("Leading environment assignments are skipped")
    func commandSkipsEnvironment() {
        #expect(ConductorCLIID.detect(command: "FOO=bar claude", title: nil) == .claudeCode)
        #expect(
            ConductorCLIID.detect(command: "A=1 B_2=x /bin/codex run", title: nil) == .codex)
    }

    @Test("Shells and unknown commands are not agents")
    func shellsAreNotAgents() {
        for command in ["zsh", "/bin/bash", "-zsh", "fish", "vim notes.md", "swift build", ""] {
            #expect(ConductorCLIID.detect(command: command, title: nil) == nil)
        }
        #expect(ConductorCLIID.detect(command: nil, title: nil) == nil)
        #expect(ConductorCLIID.detect(command: "FOO=bar", title: nil) == nil)
    }

    @Test("Only the first word counts, so arguments never match")
    func argumentsDoNotMatch() {
        #expect(ConductorCLIID.detect(command: "echo claude", title: nil) == nil)
        #expect(ConductorCLIID.detect(command: "git commit -m codex", title: nil) == nil)
        #expect(ConductorCLIID.detect(command: "clauded", title: nil) == nil)
    }

    @Test(
        "Terminal titles name the agent, with or without a status glyph",
        arguments: [
            ("claude", ConductorCLIID.claudeCode),
            ("✳ claude", .claudeCode),
            ("✳ Claude Code", .claudeCode),
            ("Claude Code", .claudeCode),
            ("⠂ codex", .codex),
            ("OpenAI Codex", .codex),
            ("Codex", .codex),
            ("OpenCode", .openCode),
            ("Open Code", .openCode),
            ("Gemini CLI", .geminiCLI),
            ("gemini", .geminiCLI),
            ("Cursor Agent", .cursor),
            ("cursor-agent", .cursor),
            ("Kimi CLI", .kimi),
            ("cline", .cline),
            ("claude — ~/work/rafu", .claudeCode),
        ])
    func titles(title: String, expected: ConductorCLIID) {
        #expect(ConductorCLIID.detect(command: nil, title: title) == expected)
    }

    @Test("Titles of shells and directories are not agents")
    func shellTitlesAreNotAgents() {
        for title in ["zsh", "bash 2", "~/work/rafu", "/usr/bin", "vim", "", "✳", "  "] {
            #expect(ConductorCLIID.detect(command: nil, title: title) == nil)
        }
    }

    @Test("A recognised command wins over a conflicting title")
    func commandWinsOverTitle() {
        #expect(ConductorCLIID.detect(command: "codex", title: "claude") == .codex)
        #expect(ConductorCLIID.detect(command: "zsh", title: "claude") == .claudeCode)
    }

    @Test("Every agent CLI has a menu fallback symbol")
    func menuFallbackSymbol() {
        for cli in ConductorCLIID.allCases {
            #expect(!cli.menuFallbackSymbolName.isEmpty)
        }
    }
}
