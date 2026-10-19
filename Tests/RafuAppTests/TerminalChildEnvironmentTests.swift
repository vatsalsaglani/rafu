import Testing

@testable import RafuApp

struct TerminalChildEnvironmentTests {
    @Test func removesClaudeCodeHostSessionKeysButKeepsUserConfiguration() {
        let base: [String: String] = [
            "CLAUDECODE": "1",
            "CLAUDE_PID": "4242",
            "CLAUDE_EFFORT": "40",
            "CLAUDE_CODE_SESSION_ID": "fixture-session",
            "CLAUDE_CODE_CHILD_SESSION": "1",
            "CLAUDE_CODE_ENTRYPOINT": "fixture-entry",
            "CLAUDE_CODE_EXECPATH": "/fixture/claude",
            "CLAUDE_CODE_MESSAGING_SOCKET": "/fixture/socket",
            "CLAUDE_CODE_MESSAGING_TOKEN": "fixture-messaging-token",
            "CLAUDE_CODE_BRIDGE_SESSION_ID": "fixture-bridge",
            "CLAUDE_CODE_SESSION_ATTENDED": "1",
            "ANTHROPIC_API_KEY": "fixture-anthropic-key",
            "ANTHROPIC_BASE_URL": "https://fixture.example",
            "CLAUDE_CONFIG_DIR": "/fixture/claude-config",
            "CLAUDE_CODE_USE_BEDROCK": "1",
            "HOME": "/fixture/home",
            "PATH": "/usr/bin:/bin",
        ]
        let scrubbed = TerminalChildEnvironment.scrubbed(base)
        for key in [
            "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_CODE_SESSION_ID",
            "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH",
            "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
            "CLAUDE_CODE_BRIDGE_SESSION_ID", "CLAUDE_CODE_SESSION_ATTENDED",
        ] {
            #expect(scrubbed[key] == nil, "\(key) should have been removed")
        }
        for key in [
            "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "CLAUDE_CONFIG_DIR",
            "CLAUDE_CODE_USE_BEDROCK",
            "HOME", "PATH",
        ] {
            #expect(scrubbed[key] == base[key], "\(key) should have been kept")
        }
    }

    @Test func leavesAnEnvironmentWithoutClaudeCodeKeysUnchanged() {
        let base: [String: String] = ["HOME": "/fixture/home", "PATH": "/usr/bin:/bin"]
        #expect(TerminalChildEnvironment.scrubbed(base) == base)
    }
}
