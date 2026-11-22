import Foundation
import Testing

@testable import RafuCore

/// Lines in the shapes of the saved results named by
/// `meeting-hidden-agent-limits.md` (fields cut to the ones Rafu reads).
enum AgentStreamSample {
    static let claudeInit =
        #"{"type":"system","subtype":"init","cwd":"/D","tools":["Glob","Grep","Read"],"mcp_servers":[],"model":"claude-haiku-5-5","permissionMode":"dontAsk","claude_code_version":"2.1.330"}"#
    static let claudeUIEvent = #"{"type":"system","subtype":"ui_invalidate","event":"ui.render"}"#
    static func claudeResult(_ text: String, isError: Bool = false) -> String {
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        return
            #"{"type":"result","subtype":"success","is_error":\#(isError),"result":"\#(escaped)"}"#
    }
    static let claudeNotLoggedIn = claudeResult("Not logged in · Please run /login", isError: true)

    static let codexThread = #"{"type":"thread.started","thread_id":"01a2"}"#
    static let codexTurnStarted = #"{"type":"turn.started"}"#
    static func codexMessage(_ text: String) -> String {
        #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"\#(text)"}}"#
    }
    static let codexTurnCompleted = #"{"type":"turn.completed","usage":{"input_tokens":6901}}"#
    static let codex401 =
        #"{"type":"error","message":"Reconnecting... 2/5 (unexpected status 401 Unauthorized: Missing bearer or basic authentication in header, url: wss://api.openai.com/v1/responses)"}"#
    static let codexUnrecognized =
        #"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Codex is ignoring 1 unrecognized configuration setting. Check for typos or deprecated settings.\n  session-flags: `include_apply_patch_tool` is ignored."}}"#
    static let codexTurnFailed =
        #"{"type":"turn.failed","error":{"message":"stream disconnected before completion"}}"#
}

@Suite("Hidden meeting agent: stream parsers")
struct MeetingAgentParserTests {
    private func feed<P: MeetingAgentStreamParsing>(_ parser: inout P, _ lines: [String])
        -> [MeetingAgentStreamVerdict]
    {
        lines.map { parser.consume(line: Data($0.utf8)) }
    }

    @Test("Claude: an accepted init event and a result give the answer")
    func claudeAccepted() {
        var parser = ClaudeStreamParser()
        let verdicts = feed(
            &parser,
            [
                AgentStreamSample.claudeUIEvent, "not json", AgentStreamSample.claudeInit,
                AgentStreamSample.claudeResult("Ships March 14 [t7]"),
            ])
        #expect(verdicts == [.more, .more, .more, .more])
        #expect(parser.initCheck == .accepted)
        #expect(parser.cliVersion == "2.1.330")
        #expect(parser.answer == "Ships March 14 [t7]")
        #expect(!parser.notLoggedIn)
    }

    @Test("Claude: an extra tool, an MCP server or another mode is refused at once")
    func claudeRefused() {
        let cases = [
            AgentStreamSample.claudeInit.replacingOccurrences(
                of: #"["Glob","Grep","Read"]"#, with: #"["Bash","Glob","Grep","Read"]"#),
            AgentStreamSample.claudeInit.replacingOccurrences(
                of: #"["Glob","Grep","Read"]"#, with: #"["Glob","Read"]"#),
            AgentStreamSample.claudeInit.replacingOccurrences(
                of: #""mcp_servers":[]"#, with: #""mcp_servers":[{"name":"gmail"}]"#),
            AgentStreamSample.claudeInit.replacingOccurrences(of: "dontAsk", with: "default"),
            AgentStreamSample.claudeInit.replacingOccurrences(of: #""mcp_servers":[],"#, with: ""),
        ]
        for line in cases {
            var parser = ClaudeStreamParser()
            #expect(parser.consume(line: Data(line.utf8)) == .stop)
            #expect(parser.initCheck == .refused)
            _ = parser.consume(line: Data(AgentStreamSample.claudeResult("x").utf8))
            #expect(parser.answer == nil)
        }
    }

    @Test("Claude: a result before an init event is not an answer")
    func claudeResultWithoutInit() {
        var parser = ClaudeStreamParser()
        #expect(parser.consume(line: Data(AgentStreamSample.claudeResult("x").utf8)) == .stop)
        #expect(parser.answer == nil)
    }

    @Test("Claude: not logged in is detected from is_error, not subtype")
    func claudeNotLoggedIn() {
        var parser = ClaudeStreamParser()
        let verdicts = feed(
            &parser,
            [
                AgentStreamSample.claudeUIEvent, AgentStreamSample.claudeInit,
                AgentStreamSample.claudeNotLoggedIn,
            ])
        #expect(verdicts.last == .stop)
        #expect(parser.notLoggedIn)
        #expect(parser.answer == nil)
    }

    @Test("Codex: the last agent_message of the completed turn wins")
    func codexLastMessage() {
        var parser = CodexStreamParser()
        _ = feed(
            &parser,
            [
                AgentStreamSample.codexThread, AgentStreamSample.codexTurnStarted,
                AgentStreamSample.codexMessage("Looking at the transcript."),
                AgentStreamSample.codexMessage("The team ships on March 14 [t12]."),
            ])
        #expect(parser.answer == nil)
        _ = feed(&parser, [AgentStreamSample.codexTurnCompleted])
        #expect(parser.answer == "The team ships on March 14 [t12].")
    }

    @Test("Codex: the first 401 error stops the run as not signed in")
    func codex401() {
        var parser = CodexStreamParser()
        let verdicts = feed(
            &parser,
            [
                AgentStreamSample.codexThread, AgentStreamSample.codexTurnStarted,
                AgentStreamSample.codex401,
            ])
        #expect(verdicts == [.more, .more, .stop])
        #expect(parser.notSignedIn)
        #expect(parser.answer == nil)
    }

    @Test("Codex: an unrecognized setting stops the run")
    func codexUnrecognized() {
        var parser = CodexStreamParser()
        #expect(parser.consume(line: Data(AgentStreamSample.codexUnrecognized.utf8)) == .stop)
        #expect(parser.unrecognizedSetting)
        _ = feed(
            &parser, [AgentStreamSample.codexMessage("x"), AgentStreamSample.codexTurnCompleted])
        #expect(parser.answer == nil)
    }

    @Test("Codex: a failed turn gives no answer")
    func codexTurnFailed() {
        var parser = CodexStreamParser()
        let verdicts = feed(
            &parser,
            [
                AgentStreamSample.codexTurnStarted, AgentStreamSample.codexMessage("partial"),
                AgentStreamSample.codexTurnFailed,
            ])
        #expect(verdicts.last == .stop)
        #expect(parser.turnFailed)
        #expect(!parser.notSignedIn)
        #expect(parser.answer == nil)
    }

    @Test("The line splitter bounds one line and the whole output")
    func lineSplitter() throws {
        var splitter = MeetingAgentLineSplitter(maximumLineBytes: 8, maximumOutputBytes: 32)
        #expect(try splitter.append(Data("ab\ncd".utf8)) == [Data("ab".utf8)])
        #expect(try splitter.append(Data("e\n".utf8)) == [Data("cde".utf8)])
        #expect(splitter.finish() == nil)
        #expect(throws: MeetingAgentLineSplitter.Problem.lineTooLong) {
            try splitter.append(Data("123456789".utf8))
        }
        var small = MeetingAgentLineSplitter(maximumLineBytes: 8, maximumOutputBytes: 4)
        #expect(throws: MeetingAgentLineSplitter.Problem.outputTooLarge) {
            try small.append(Data("1\n2\n3".utf8))
        }
    }
}

@Suite("Hidden meeting agent: citations and names")
struct MeetingAgentReplyParserTests {
    private func ids(_ numbers: [Int]) -> [MeetingTurnID] { numbers.map(MeetingTurnID.init) }

    @Test("Each citation form of the limits note is read")
    func citationForms() {
        #expect(MeetingCitationParser.citations(in: "Ships [t7].") == ids([7]))
        #expect(MeetingCitationParser.citations(in: "A [t11][t12] b") == ids([11, 12]))
        #expect(MeetingCitationParser.citations(in: "A [t7] [t11]") == ids([7, 11]))
        #expect(MeetingCitationParser.citations(in: "A [t11–t12]") == ids([11, 12]))
        #expect(MeetingCitationParser.citations(in: "A [t11-t13]") == ids([11, 12, 13]))
        #expect(MeetingCitationParser.citations(in: "[t7] again [t7] and [t2]") == ids([7, 2]))
    }

    @Test("A range is bounded and other bracket text is not a citation")
    func notCitations() {
        #expect(MeetingCitationParser.citations(in: "[t1-t500]") == ids(Array(1...20)))
        #expect(MeetingCitationParser.citations(in: "[t9-t3]").isEmpty)
        #expect(MeetingCitationParser.citations(in: "[https://example.com/t7]").isEmpty)
        #expect(MeetingCitationParser.citations(in: "[link](https://x.y) [t9 12:27]").isEmpty)
        #expect(MeetingCitationParser.citations(in: "[t11, t12] [T7] [t] [t-1] [7]").isEmpty)
        #expect(MeetingCitationParser.citations(in: "[t99999999999]").isEmpty)
        #expect(MeetingCitationParser.citations(in: "[[t3]] [t4") == ids([3]))
    }

    @Test("Good name JSON is read; me and labels with no evidence are dropped")
    func goodNames() throws {
        let reply = try MeetingNameReplyParser.parse(
            #"{"speaker-2": {"name": "  Priya ", "evidence": ["t1", "t13"]}, "me": {"name": "Vee", "evidence": ["t2"]}, "them": {"name": "Ann", "evidence": []}}"#
        )
        #expect(reply.names == [.speaker(2): "Priya"])
        #expect(reply.evidence[.speaker(2)] == ids([1, 13]))
        let fenced = try MeetingNameReplyParser.parse(
            "```json\n{\"them\": {\"name\": \"Ann\", \"evidence\": [\"t4\"]}}\n```")
        #expect(fenced.names == [.them: "Ann"])
    }

    @Test("A long name, a bad key, a bad id or bad JSON fails the reply")
    func badNames() {
        let bad = [
            #"{"speaker-2": {"name": "\#(String(repeating: "a", count: 81))", "evidence": ["t1"]}}"#,
            #"{"speaker-2": {"name": "Pri\nya", "evidence": ["t1"]}}"#,
            #"{"Priya": {"name": "Priya", "evidence": ["t1"]}}"#,
            #"{"speaker-2": {"name": "Priya", "evidence": ["1"]}}"#,
            #"{"speaker-2": "Priya"}"#,
            #"Here you go: {"speaker-2": {"name": "Priya", "evidence": ["t1"]}}"#,
            "[]",
            "not json",
        ]
        for text in bad {
            #expect(throws: MeetingNameReplyParser.Problem.failed) {
                try MeetingNameReplyParser.parse(text)
            }
        }
    }
}
