import Foundation
import Testing

@testable import RafuCore

@Suite("Hidden meeting agent: streamed text and tool checks")
struct MeetingAgentStreamingParserTests {
    private static func delta(_ text: String, parent: String = "null") -> String {
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}},"parent_tool_use_id":\#(parent)}"#
    }

    private static let messageStart =
        #"{"type":"stream_event","event":{"type":"message_start","message":{"content":[]}},"parent_tool_use_id":null}"#

    private static func toolStart(_ name: String, type: String = "tool_use") -> String {
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"\#(type)","id":"toolu_0","name":"\#(name)","input":{}}},"parent_tool_use_id":null}"#
    }

    /// Feeds each line and collects the text events.
    private func run(_ lines: [String], into parser: inout ClaudeStreamParser)
        -> (verdicts: [MeetingAgentStreamVerdict], events: [MeetingAgentTextEvent])
    {
        var verdicts: [MeetingAgentStreamVerdict] = []
        var events: [MeetingAgentTextEvent] = []
        for line in lines {
            verdicts.append(parser.consume(line: Data(line.utf8)))
            events += parser.takeTextEvents()
        }
        return (verdicts, events)
    }

    @Test("Claude: the recorded run streams its deltas in order, and the result is the answer")
    func recordedRun() {
        var parser = ClaudeStreamParser()
        let (verdicts, events) = run(ClaudeRecordedStream.lines, into: &parser)
        #expect(verdicts.allSatisfy { $0 == .more })
        #expect(
            events == [
                .reset, .reset, .delta("The probe works. N"), .delta("othing to"), .delta(" add"),
                .delta("."),
            ])
        #expect(parser.initCheck == .accepted)
        #expect(!parser.forbiddenTool)
        #expect(parser.answer == "The probe works. Nothing to add.")
    }

    @Test("Claude: a new message resets the streamed text; the result text wins")
    func resetAndResultWins() {
        var parser = ClaudeStreamParser()
        let (_, events) = run(
            [
                AgentStreamSample.claudeUIEvent, Self.delta("early"), AgentStreamSample.claudeInit,
                Self.messageStart, Self.delta("Looking"), Self.messageStart,
                Self.delta("Ships [t2]"), AgentStreamSample.claudeResult("Ships on March 14 [t2]"),
            ], into: &parser)
        // A delta before the init event is never shown.
        #expect(events == [.reset, .delta("Looking"), .reset, .delta("Ships [t2]")])
        #expect(parser.answer == "Ships on March 14 [t2]")
    }

    @Test("Claude: delta text is cleaned and a sub-agent delta is not shown")
    func deltaCleaning() {
        var parser = ClaudeStreamParser()
        let (_, events) = run(
            [
                AgentStreamSample.claudeInit, Self.delta(#"a\u0007b\tc "#),
                Self.delta("hidden", parent: #""toolu_9""#),
            ], into: &parser)
        #expect(events == [.delta("ab c ")])
    }

    @Test("Claude: streamed text stops at the answer limit")
    func deltaLimit() {
        var parser = ClaudeStreamParser()
        let piece = String(repeating: "a", count: 1_024)
        var lines = [AgentStreamSample.claudeInit]
        lines += Array(repeating: Self.delta(piece), count: 40)
        let (_, events) = run(lines, into: &parser)
        let shown = events.reduce(0) { total, event in
            if case .delta(let text) = event { return total + text.utf8.count }
            return total
        }
        #expect(shown == 32 * 1_024)
    }

    @Test("Claude: a tool call outside Glob, Grep and Read stops the run")
    func forbiddenTool() {
        for line in [
            Self.toolStart("Bash"), Self.toolStart("Write"),
            Self.toolStart("x", type: "server_tool_use"), Self.toolStart("y", type: "mcp_tool_use"),
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{}}]}}"#,
        ] {
            var parser = ClaudeStreamParser()
            let (verdicts, _) = run(
                [AgentStreamSample.claudeInit, line, AgentStreamSample.claudeResult("x")],
                into: &parser)
            #expect(verdicts[1] == .stop, "\(line)")
            #expect(parser.forbiddenTool)
            #expect(parser.answer == nil)
        }
        var allowed = ClaudeStreamParser()
        let (verdicts, _) = run(
            [AgentStreamSample.claudeInit, Self.toolStart("Read"), Self.toolStart("Grep")],
            into: &allowed)
        #expect(verdicts == [.more, .more, .more])
    }

    @Test("Codex: an item type outside agent_message, reasoning and error stops the run")
    func codexItemTypes() {
        let mcp =
            #"{"type":"item.started","item":{"id":"item_1","type":"mcp_tool_call","server":"codex","tool":"list_mcp_resources"}}"#
        var parser = CodexStreamParser()
        #expect(parser.consume(line: Data(AgentStreamSample.codexTurnStarted.utf8)) == .more)
        #expect(
            parser.consume(
                line: Data(
                    #"{"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"x"}}"#
                        .utf8)) == .more)
        #expect(parser.consume(line: Data(mcp.utf8)) == .stop)
        #expect(parser.toolEvent)
        _ = parser.consume(line: Data(AgentStreamSample.codexMessage("x").utf8))
        _ = parser.consume(line: Data(AgentStreamSample.codexTurnCompleted.utf8))
        #expect(parser.answer == nil)

        var noType = CodexStreamParser()
        #expect(noType.consume(line: Data(#"{"type":"item.updated","item":{}}"#.utf8)) == .stop)
    }

    @Test("Codex: one answer at the end and no streamed text")
    func codexNoDeltas() {
        var parser = CodexStreamParser()
        for line in [
            AgentStreamSample.codexThread, AgentStreamSample.codexTurnStarted,
            AgentStreamSample.codexMessage("Ships [t2]"), AgentStreamSample.codexTurnCompleted,
        ] {
            #expect(parser.consume(line: Data(line.utf8)) == .more)
            #expect(parser.takeTextEvents().isEmpty)
        }
        #expect(parser.answer == "Ships [t2]")
    }
}
