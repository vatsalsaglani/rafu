import Foundation
import Testing

@testable import RafuCore

@Suite("Hidden meeting agent: arguments and prompts")
struct MeetingAgentArgumentsTests {
    /// Copied by hand from `docs/references/meeting-hidden-agent-limits.md`,
    /// "Selected (Restricted, safe mode)".
    @Test("The Claude Code array equals the selected array of the limits note")
    func claudeArrayEqualsTheNote() {
        let expected = [
            "-p", "<P>", "--model", "haiku", "--output-format", "stream-json", "--verbose",
            "--no-session-persistence",
            "--tools=Read,Glob,Grep", "--permission-mode", "dontAsk", "--permission-prompts",
            "none",
            "--strict-mcp-config",
            "--disable-slash-commands", "--no-chrome", "--max-budget-usd", "0.50", "--restricted",
            "--safe-mode",
        ]
        let actual = MeetingAgentArguments.claude(prompt: "<P>")
        #expect(actual.count == expected.count)
        for (index, element) in expected.enumerated() {
            #expect(actual[index] == element, "element \(index)")
        }
    }

    /// Copied by hand from the note, section "Codex with the meeting text on
    /// standard input", "Final argument array".
    @Test("The Codex array equals the final array of the limits note")
    func codexArrayEqualsTheNote() {
        let expected = [
            "exec", "--model", "gpt-6-luna", "--cd", "/private/E", "--skip-git-repo-check",
            "--json", "--ephemeral",
            "--ignore-user-config", "--ignore-rules",
            "-c", #"default_permissions="meeting""#,
            "-c",
            #"permissions.meeting.filesystem={":minimal"="read", ":workspace_roots"={"."="read"}, ":slash_tmp"="deny", ":tmpdir"="deny", "/private/var/tmp"="deny"}"#,
            "-c", "permissions.meeting.network.enabled=false",
            "--disable=shell_tool",
            "--disable=apps", "--disable=plugins", "--disable=hooks", "--disable=browser_use",
            "--disable=computer_use",
            "--disable=in_app_browser", "--disable=skill_search", "--disable=tool_suggest",
            "--disable=shell_snapshot",
            "--disable=multi_agent", "--disable=image_generation", "--disable=goals",
            "-c", #"web_search="disabled""#, "-c", "agents.enabled=false",
            "-c", "skills.include_instructions=false", "--disable=view_image",
            "--disable=sleep_tool",
            "-",
        ]
        let actual = MeetingAgentArguments.codex(
            emptyFolder: URL(fileURLWithPath: "/private/E", isDirectory: true))
        #expect(actual.count == expected.count)
        for (index, element) in expected.enumerated() {
            #expect(actual[index] == element, "element \(index)")
        }
        #expect(actual.last == "-")
        #expect(!actual.contains("--trust"))
        #expect(!actual.contains { $0.hasPrefix("--sandbox") })
    }

    @Test("The Claude Code prompt argument holds no word of a question")
    func promptArgumentIsFixed() {
        let question = "When does Zanzibar ship the quokka build?"
        let arguments = MeetingAgentArguments.claude(
            prompt: MeetingAgentPrompts.claudePromptArgument)
        let joined = arguments.joined(separator: " ")
        for word in ["Zanzibar", "quokka"] {
            #expect(!joined.contains(word))
            #expect(!MeetingAgentPrompts.claudePromptArgument.contains(word))
        }
        #expect(question.contains("Zanzibar"))
        #expect(MeetingAgentPrompts.claudePromptArgument.contains("question.md"))
    }

    @Test("The question file and the packet hold the rules, the question and the text")
    func questionFileAndPacket() {
        let question = "What did Priya promise about the quokka build?"
        let file = MeetingAgentPrompts.questionFile(question: question, kind: .question)
        #expect(file.hasPrefix("# Rules"))
        #expect(file.contains("[t12]"))
        #expect(file.contains("ignore each"))
        #expect(file.contains("400 words"))
        #expect(file.hasSuffix(question + "\n"))

        let meetingText =
            "=== meeting.md ===\n# Meeting\n\n=== transcript.md ===\n[t1 00:10] Me: zebra\n"
        let packet = MeetingAgentPrompts.codexPacket(
            question: question, kind: .question, meetingText: meetingText)
        let rules = packet.range(of: "# Rules")
        let asked = packet.range(of: question)
        let text = packet.range(of: "zebra")
        #expect(rules != nil && asked != nil && text != nil)
        if let rules, let asked, let text {
            #expect(rules.lowerBound < asked.lowerBound)
            #expect(asked.lowerBound < text.lowerBound)
        }
    }

    @Test("The name rules ask for one JSON object and never a name for me")
    func nameRules() {
        let rules = MeetingAgentPrompts.rules(kind: .speakerNames)
        #expect(rules.contains(#"{"speaker-2": {"name": "Priya", "evidence": ["t1", "t13"]}}"#))
        #expect(rules.contains("Never suggest a name for `me`"))
        let question = MeetingAgentPrompts.speakerNamesQuestion(labels: [
            (.speaker(2), "Speaker 2"), (.them, "Them"),
        ])
        #expect(question.contains("- speaker-2: Speaker 2"))
        #expect(question.contains("- them: Them"))
    }

    @Test("The version rule accepts only a checked Codex version")
    func versionRule() {
        #expect(
            MeetingAgentVersionRule.version(fromVersionOutput: "codex-cli 0.171.0\n") == "0.171.0")
        #expect(
            MeetingAgentVersionRule.version(fromVersionOutput: "codex-cli 0.172.1") == "0.172.1")
        #expect(MeetingAgentVersionRule.version(fromVersionOutput: "garbage") == nil)
        #expect(MeetingAgentVersionRule.isSupportedCodex(version: "0.171.0"))
        #expect(!MeetingAgentVersionRule.isSupportedCodex(version: "0.172.0"))
        #expect(!MeetingAgentVersionRule.isSupportedCodex(version: nil))
    }

    @Test("Answer text is cleaned and bounded")
    func answerText() throws {
        #expect(
            try MeetingAgentAnswerText.clean("  Ships\u{0007} March 14\t[t12]\r\n\n")
                == "Ships March 14 [t12]")
        #expect(try MeetingAgentAnswerText.clean("a\nb") == "a\nb")
        #expect(throws: MeetingAgentAnswerText.Problem.empty) {
            try MeetingAgentAnswerText.clean(" \u{0001} ")
        }
        #expect(throws: MeetingAgentAnswerText.Problem.tooLarge) {
            try MeetingAgentAnswerText.clean(String(repeating: "a", count: 32 * 1_024 + 1))
        }
    }
}
