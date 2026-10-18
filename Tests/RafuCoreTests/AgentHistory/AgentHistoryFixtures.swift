import Foundation

// Synthetic transcript fixtures for the Agent History parsers. Every value
// here is invented; none is copied from a real Claude Code or Codex session.
// The shapes follow the formats recorded in docs/references/agent-history.md.

enum AgentHistoryFixtures {
    static let claudeSessionID = "11111111-1111-4111-8111-111111111111"
    static let claudeImageSessionID = "33333333-3333-4333-8333-333333333333"
    static let codexSessionID = "22222222-2222-4222-8222-222222222222"
    static let codexSubagentID = "44444444-4444-4444-8444-444444444444"

    private static let claudeCommon =
        #""sessionId":"11111111-1111-4111-8111-111111111111","cwd":"/work/alpha","isSidechain":false,"version":"2.1.0""#

    /// A Claude Code session with a generated title, a slash command, a
    /// prompt, thinking, a tool call and result, a malformed line, a
    /// sidechain entry, and an unknown entry type.
    static let claudeSession =
        [
            #"{"type":"ai-title","aiTitle":"Add a login form","sessionId":"11111111-1111-4111-8111-111111111111"}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>Caveat: synthetic.</local-command-caveat>"},"timestamp":"2026-01-02T10:00:00.000Z","gitBranch":"main",\#(claudeCommon)}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/init</command-name>\n<command-message>init</command-message>\n<command-args></command-args>"},"timestamp":"2026-01-02T10:00:01.000Z","gitBranch":"main",\#(claudeCommon)}"#,
            #"{"type":"user","message":{"role":"user","content":"Please add a login form with **email** and password."},"timestamp":"2026-01-02T10:00:05Z","gitBranch":"main",\#(claudeCommon)}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Plan the form first."}]},"timestamp":"2026-01-02T10:00:06.000Z","gitBranch":"main",\#(claudeCommon)}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will add the form.\n\n```swift\nstruct LoginForm {}\n```"}]},"timestamp":"2026-01-02T10:00:07.000Z","gitBranch":"main",\#(claudeCommon)}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Edit","input":{"file_path":"/work/alpha/Login.swift","old_string":"a","new_string":"b"}}]},"timestamp":"2026-01-02T10:00:08.000Z","gitBranch":"main",\#(claudeCommon)}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"\nFile updated.\nDone","is_error":false}]},"timestamp":"2026-01-02T10:00:09.000Z","gitBranch":"main",\#(claudeCommon)}"#,
            "this line is not JSON",
            #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"A sidechain prompt"},"timestamp":"2026-01-02T10:01:00.000Z","sessionId":"11111111-1111-4111-8111-111111111111","cwd":"/work/alpha"}"#,
            #"{"type":"future-entry-type","value":1}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":"Finished."},"timestamp":"2026-01-02T10:05:00.000Z","gitBranch":"feature/login",\#(claudeCommon)}"#,
        ].joined(separator: "\n") + "\n"

    /// No title entry: the title comes from the first real prompt, which is a
    /// block list with an image.
    static let claudeImageSession =
        [
            #"{"type":"user","message":{"role":"user","content":"<system-reminder>Synthetic reminder.</system-reminder>"},"timestamp":"2026-01-03T09:00:00.000Z","cwd":"/work/alpha/app","sessionId":"33333333-3333-4333-8333-333333333333"}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","data":"AAAA"}},{"type":"text","text":"What does   this\nscreenshot show?"}]},"timestamp":"2026-01-03T09:00:02.000Z","cwd":"/work/alpha/app","sessionId":"33333333-3333-4333-8333-333333333333"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"A settings window."}]},"timestamp":"2026-01-03T09:00:04.000Z","cwd":"/work/alpha/app","sessionId":"33333333-3333-4333-8333-333333333333"}"#,
        ].joined(separator: "\n") + "\n"

    /// A file with only bookkeeping entries: not a session to list.
    static let claudeEmptySession =
        [
            #"{"type":"mode","mode":"normal","sessionId":"55555555-5555-4555-8555-555555555555"}"#,
            #"{"type":"last-prompt","lastPrompt":"","sessionId":"55555555-5555-4555-8555-555555555555"}"#,
        ].joined(separator: "\n") + "\n"

    /// A Codex rollout with injected context, reasoning, a failing shell
    /// call, and a reply.
    static let codexRollout =
        [
            #"{"timestamp":"2026-02-03T08:00:00.000Z","type":"session_meta","payload":{"id":"22222222-2222-4222-8222-222222222222","timestamp":"2026-02-03T08:00:00.000Z","cwd":"/work/beta","originator":"codex_cli_rs","cli_version":"0.50.0","source":"cli","git":{"branch":"develop","commit_hash":"0000000"}}}"#,
            #"{"timestamp":"2026-02-03T08:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<user_instructions>\nBe brief.\n</user_instructions>"}]}}"#,
            #"{"timestamp":"2026-02-03T08:00:01.500Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n  <cwd>/work/beta</cwd>\n</environment_context>"}]}}"#,
            #"{"timestamp":"2026-02-03T08:00:02.000Z","type":"turn_context","payload":{"cwd":"/work/beta","model":"example-model"}}"#,
            #"{"timestamp":"2026-02-03T08:00:03.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix the failing test in parser.rs"}]}}"#,
            #"{"timestamp":"2026-02-03T08:00:03.100Z","type":"event_msg","payload":{"type":"user_message","message":"Fix the failing test in parser.rs"}}"#,
            #"{"timestamp":"2026-02-03T08:00:04.000Z","type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"Read the test first."}],"encrypted_content":"opaque"}}"#,
            #"{"timestamp":"2026-02-03T08:00:05.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"cargo\",\"test\"]}","call_id":"call_1"}}"#,
            #"{"timestamp":"2026-02-03T08:00:06.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":"{\"output\":\"1 test failed\",\"metadata\":{\"exit_code\":101}}"}}"#,
            "{broken json",
            #"{"timestamp":"2026-02-03T08:00:07.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"The test now passes."}]}}"#,
            #"{"timestamp":"2026-02-03T08:10:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#,
        ].joined(separator: "\n") + "\n"

    /// An older rollout shape with only event messages.
    static let codexEventOnlyRollout =
        [
            #"{"timestamp":"2026-02-04T08:00:00.000Z","type":"session_meta","payload":{"id":"66666666-6666-4666-8666-666666666666","timestamp":"2026-02-04T08:00:00.000Z","cwd":"/work/gamma","originator":"codex_cli_rs","cli_version":"0.20.0"}}"#,
            #"{"timestamp":"2026-02-04T08:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"List the files"}}"#,
            #"{"timestamp":"2026-02-04T08:00:02.000Z","type":"event_msg","payload":{"type":"agent_message","message":"Here are the files."}}"#,
        ].joined(separator: "\n") + "\n"

    /// A helper thread: hidden from the list.
    static let codexSubagentRollout =
        [
            #"{"timestamp":"2026-02-03T09:00:00.000Z","type":"session_meta","payload":{"id":"44444444-4444-4444-8444-444444444444","timestamp":"2026-02-03T09:00:00.000Z","cwd":"/work/beta","originator":"codex_cli_rs","cli_version":"0.50.0","source":{"subagent":{"other":"review"}}}}"#,
            #"{"timestamp":"2026-02-03T09:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Review the diff"}]}}"#,
        ].joined(separator: "\n") + "\n"

    /// Thread names: append-only; the last complete row wins; a partial
    /// final row is ignored.
    static let codexSessionIndex =
        [
            #"{"id":"22222222-2222-4222-8222-222222222222","thread_name":"Parser fix","updated_at":"2026-02-03T08:01:00Z"}"#,
            #"{"id":"other","thread_name":"Unrelated"}"#,
            #"{"id":"22222222-2222-4222-8222-222222222222","thread_name":"Parser test fix"}"#,
        ].joined(separator: "\n") + "\n"
        + #"{"id":"22222222-2222-4222-8222-222222222222","thread_name":"Partial"#

    /// A temporary folder with a Claude Code config folder and a Codex home.
    struct Homes {
        let root: URL
        let locations: AgentHistoryLocationsSnapshot

        var claudeFile: URL {
            locations.claudeProjects.appendingPathComponent("-work-alpha")
                .appendingPathComponent("\(AgentHistoryFixtures.claudeSessionID).jsonl")
        }

        var codexFile: URL {
            locations.codexHome.appendingPathComponent("sessions/2026/02/03")
                .appendingPathComponent(
                    "rollout-2026-02-03T08-00-00-\(AgentHistoryFixtures.codexSessionID).jsonl")
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    struct AgentHistoryLocationsSnapshot {
        let claudeProjects: URL
        let codexHome: URL
    }

    static func makeHomes() throws -> Homes {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("rafu-agent-history-\(UUID().uuidString)", isDirectory: true)
        let projects = root.appendingPathComponent("claude/projects", isDirectory: true)
        let codex = root.appendingPathComponent("codex", isDirectory: true)
        let homes = Homes(
            root: root,
            locations: AgentHistoryLocationsSnapshot(claudeProjects: projects, codexHome: codex))
        try write(claudeSession, to: homes.claudeFile)
        try write(
            claudeImageSession,
            to: projects.appendingPathComponent("-work-alpha-app")
                .appendingPathComponent("\(claudeImageSessionID).jsonl"))
        try write(
            claudeEmptySession,
            to: projects.appendingPathComponent("-work-alpha")
                .appendingPathComponent("55555555-5555-4555-8555-555555555555.jsonl"))
        // A subagent transcript one level deeper must be skipped.
        try write(
            claudeImageSession,
            to: projects.appendingPathComponent("-work-alpha/subagents")
                .appendingPathComponent("agent-1.jsonl"))
        try write(codexRollout, to: homes.codexFile)
        try write(
            codexSubagentRollout,
            to: codex.appendingPathComponent("sessions/2026/02/03")
                .appendingPathComponent(
                    "rollout-2026-02-03T09-00-00-\(codexSubagentID).jsonl"))
        try write(codexSessionIndex, to: codex.appendingPathComponent("session_index.jsonl"))
        return homes
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    static func temporaryFile(_ text: String, name: String = "fixture.jsonl") throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("rafu-agent-history-\(UUID().uuidString)", isDirectory: true)
        let url = folder.appendingPathComponent(name)
        try write(text, to: url)
        return url
    }
}
