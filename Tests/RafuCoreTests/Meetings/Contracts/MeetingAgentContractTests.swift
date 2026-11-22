import Testing

@testable import RafuCore

@Suite("Meeting contracts: hidden agent")
struct MeetingAgentContractTests {
    @Test("An agent error and a CLI have plain names")
    func plainNames() {
        #expect(
            MeetingAgentError.notSignedIn(.codex).message
                == "Codex is not signed in. Sign in with Codex in a terminal, then try again.")
        #expect(MeetingAgentCLI.codex.providerName == "OpenAI")
        #expect(MeetingAgentCLI.claudeCode.providerName == "Anthropic")
        #expect(MeetingAgentCLI.claudeCode.displayName == "Claude Code")
        for cli in MeetingAgentCLI.allCases {
            #expect(!MeetingAgentError.notInstalled(cli).message.isEmpty)
        }
    }
}
