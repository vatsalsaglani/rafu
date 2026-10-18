import Foundation
import Testing

@testable import RafuCore

private let nodeA = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
private let nodeB = "7F9619FF-8B86-D011-B42D-00C04FC964FF"

@Test func agentToolNamesAreUniqueSnakeCaseAndListed() throws {
    let names = CanvasAgentTool.allCases.map(\.rawValue)
    #expect(Set(names).count == names.count)
    for name in names {
        #expect(name.allSatisfy { $0.isLowercase || $0 == "_" })
    }
    let definitions = CanvasAgentToolCatalog.definitions
    #expect(definitions.count == CanvasAgentTool.allCases.count)
    for definition in definitions {
        let schema = try #require(definition["inputSchema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(JSONSerialization.isValidJSONObject(definition))
    }
}

@Test func agentToolCallRoundTripsOnTheWire() throws {
    var call = CanvasAgentToolCall(tool: .terminalCreate)
    call.title = "Tests"
    call.agent = "codex"
    call.prompt = "Run the unit tests"
    call.near = nodeA
    let decoded = try JSONDecoder().decode(
        CanvasAgentToolCall.self, from: JSONEncoder().encode(call))
    #expect(decoded == call)
    let request = CanvasBridgeRequest(token: "t", operation: "tool", agentCall: call)
    #expect(
        try JSONDecoder().decode(CanvasBridgeRequest.self, from: JSONEncoder().encode(request))
            == request)
    var result = CanvasAgentToolResult(status: .pendingApproval, message: "Waiting")
    result.requestID = nodeA
    let response = CanvasBridgeResponse(toolResult: result)
    #expect(
        try JSONDecoder().decode(CanvasBridgeResponse.self, from: JSONEncoder().encode(response))
            == response)
    let legacy = Data(#"{"peers":[],"messages":[]}"#.utf8)
    #expect(try JSONDecoder().decode(CanvasBridgeResponse.self, from: legacy).toolResult == nil)
}

@Test func agentToolResultUsesSnakeCaseForAgents() throws {
    var result = CanvasAgentToolResult()
    result.callerNodeID = nodeA
    result.totalLength = 3
    let text = String(decoding: try #require(result.agentJSON()), as: UTF8.self)
    #expect(text.contains("\"caller_node_id\""))
    #expect(text.contains("\"total_length\""))
    #expect(text.contains("\"status\":\"ok\""))
}

@Test func agentToolParsingRejectsUnknownAndInvalidArguments() {
    #expect(throws: CanvasAgentToolError.unknownTool) {
        try CanvasAgentToolCall.parse(tool: "rm_rf", arguments: [:])
    }
    #expect(throws: CanvasAgentToolError.unexpectedArgument("shell")) {
        try CanvasAgentToolCall.parse(tool: "ensemble_describe", arguments: ["shell": "x"])
    }
    #expect(throws: CanvasAgentToolError.invalidArgument("node_id")) {
        try CanvasAgentToolCall.parse(tool: "note_read", arguments: ["node_id": "not-a-uuid"])
    }
    #expect(throws: CanvasAgentToolError.missingArgument("node_id")) {
        try CanvasAgentToolCall.parse(tool: "note_read", arguments: [:])
    }
    #expect(throws: CanvasAgentToolError.missingArgument("heading")) {
        try CanvasAgentToolCall.parse(
            tool: "note_write",
            arguments: ["node_id": nodeA, "text": "x", "mode": "insert_after_heading"])
    }
    #expect(throws: CanvasAgentToolError.invalidArgument("mode")) {
        try CanvasAgentToolCall.parse(
            tool: "note_write", arguments: ["node_id": nodeA, "text": "x", "mode": "rewrite"])
    }
    #expect(throws: CanvasAgentToolError.invalidArgument("text")) {
        try CanvasAgentToolCall.parse(
            tool: "note_write",
            arguments: [
                "node_id": nodeA, "mode": "append",
                "text": String(repeating: "a", count: CanvasAgentToolCall.maximumTextBytes + 1),
            ])
    }
    #expect(throws: CanvasAgentToolError.invalidArgument("x")) {
        try CanvasAgentToolCall.parse(
            tool: "note_create", arguments: ["title": "A", "x": 60_000.0])
    }
    #expect(throws: CanvasAgentToolError.invalidArgument("title")) {
        try CanvasAgentToolCall.parse(tool: "note_create", arguments: ["title": "A\nB"])
    }
    #expect(throws: CanvasAgentToolError.invalidArgument("to")) {
        try CanvasAgentToolCall.parse(
            tool: "edge_create", arguments: ["from": nodeA, "to": nodeA, "kind": "message"])
    }
    #expect(throws: CanvasAgentToolError.invalidArgument("kind")) {
        try CanvasAgentToolCall.parse(
            tool: "edge_create", arguments: ["from": nodeA, "to": nodeB, "kind": "pipe"])
    }
    #expect(throws: CanvasAgentToolError.invalidArgument("agent")) {
        try CanvasAgentToolCall.parse(tool: "terminal_create", arguments: ["agent": "bash"])
    }
    #expect(throws: CanvasAgentToolError.invalidArgument("prompt")) {
        try CanvasAgentToolCall.parse(
            tool: "terminal_create", arguments: ["agent": "gemini", "prompt": "Do it"])
    }
    #expect(throws: CanvasAgentToolError.invalidArgument("command")) {
        try CanvasAgentToolCall.parse(
            tool: "terminal_create", arguments: ["command": ["echo", "a\nrm -rf ~"]])
    }
    #expect(throws: CanvasAgentToolError.invalidArgument("command")) {
        try CanvasAgentToolCall.parse(tool: "terminal_create", arguments: ["command": "ls -la"])
    }
    #expect(throws: CanvasAgentToolError.missingArgument("text")) {
        try CanvasAgentToolCall.parse(
            tool: "terminal_send", arguments: ["node_id": nodeA, "text": "a", "command": ["ls"]])
    }
    #expect(throws: CanvasAgentToolError.missingArgument("path")) {
        try CanvasAgentToolCall.parse(tool: "node_create", arguments: ["kind": "file"])
    }
    #expect(throws: CanvasAgentToolError.invalidArgument("bundle_id")) {
        try CanvasAgentToolCall.parse(tool: "app_open", arguments: ["bundle_id": "com.x;rm"])
    }
}

@Test func agentToolParsingAcceptsAliasesAndNormalizes() throws {
    let note = try CanvasAgentToolCall.parse(
        tool: "note_create", arguments: ["title": "Plan", "markdown": "# Plan", "near": nodeA])
    #expect(note.text == "# Plan")
    #expect(note.near == nodeA)
    let diagram = try CanvasAgentToolCall.parse(
        tool: "mermaid_set", arguments: ["node_id": nodeA, "source": "graph TD; A-->B"])
    #expect(diagram.text == "graph TD; A-->B")
    let terminal = try CanvasAgentToolCall.parse(
        tool: "terminal_create",
        arguments: ["agent": "Codex", "prompt": "Fix tests", "cwd": "./Sources//RafuCore"])
    #expect(terminal.agent == "codex")
    #expect(terminal.risk == .sensitive)
    #expect(terminal.startsProcess)
    let stopped = try CanvasAgentToolCall.parse(tool: "terminal_create", arguments: [:])
    #expect(stopped.risk == .edit)
    let link = try CanvasAgentToolCall.parse(
        tool: "link_set_state", arguments: ["edge_id": nodeA, "state": "LIVE"])
    #expect(link.state == "live")
    let page = try CanvasAgentToolCall.parse(
        tool: "note_read", arguments: ["node_id": nodeA, "offset": 10.0, "length": 20])
    #expect(page.offset == 10)
    #expect(page.length == 20)
}

@Test func agentToolRisksMatchTheSafetyModel() throws {
    for tool in [CanvasAgentTool.ensembleDescribe, .noteRead, .appInspect, .actionStatus] {
        #expect(CanvasAgentToolCall(tool: tool).risk == .read)
    }
    for tool in [
        CanvasAgentTool.nodeRemove, .edgeRemove, .terminalStart, .terminalSend, .appOpen,
    ] {
        #expect(CanvasAgentToolCall(tool: tool).risk == .sensitive)
    }
    for tool in [CanvasAgentTool.noteWrite, .noteCreate, .nodeCreate, .edgeCreate, .mermaidSet] {
        #expect(CanvasAgentToolCall(tool: tool).risk == .edit)
    }
}

@Test func agentControlDecisionIsPure() {
    typealias Policy = CanvasAgentPolicy
    for mode in CanvasAgentControlMode.allCases {
        #expect(Policy.decide(mode: mode, risk: .read) == .allow)
    }
    #expect(Policy.decide(mode: .off, risk: .edit) == .deny(Policy.offMessage))
    #expect(
        Policy.decide(mode: .off, risk: .sensitive, alwaysAllowed: true)
            == .deny(Policy.offMessage))
    #expect(Policy.decide(mode: .ask, risk: .edit) == .ask)
    #expect(Policy.decide(mode: .ask, risk: .edit, alwaysAllowed: true) == .allow)
    #expect(Policy.decide(mode: .ask, risk: .sensitive, alwaysAllowed: true) == .ask)
    #expect(Policy.decide(mode: .allow, risk: .sensitive) == .allow)
    #expect(Policy.decide(mode: .allow, risk: .edit) == .allow)
}

@Test func agentRateLimiterUsesASlidingWindow() {
    var limiter = CanvasAgentRateLimiter(limit: 2, window: 60)
    let start = Date(timeIntervalSince1970: 1_000)
    let admitted = [0, 1, 2, 60, 60.5].map { limiter.admit(at: start.addingTimeInterval($0)) }
    #expect(admitted == [true, true, false, true, false])
}

@Test func agentPathsAreConfinedToTheWorkspace() {
    #expect(
        CanvasAgentPaths.normalizedRelative("Sources/./App//x.swift", allowRoot: false)
            == "Sources/App/x.swift")
    #expect(CanvasAgentPaths.normalizedRelative(".", allowRoot: true) == ".")
    #expect(CanvasAgentPaths.normalizedRelative("", allowRoot: true) == ".")
    #expect(CanvasAgentPaths.normalizedRelative(".", allowRoot: false) == nil)
    #expect(CanvasAgentPaths.normalizedRelative("/etc/passwd", allowRoot: false) == nil)
    #expect(CanvasAgentPaths.normalizedRelative("../secret", allowRoot: false) == nil)
    #expect(CanvasAgentPaths.normalizedRelative("a/../../b", allowRoot: false) == nil)
    #expect(CanvasAgentPaths.normalizedRelative("~/x", allowRoot: false) == nil)
    #expect(CanvasAgentPaths.normalizedRelative("a\u{0}b", allowRoot: false) == nil)
    #expect(CanvasAgentPaths.normalizedRelative("a\nb", allowRoot: false) == nil)
}

@Test func agentShellQuotingNeverAddsAShellOperator() {
    #expect(CanvasAgentShell.commandLine(["swift", "test"]) == "swift test")
    #expect(
        CanvasAgentShell.commandLine(["echo", "a; rm -rf ~", "$(whoami)", "it's"])
            == "echo 'a; rm -rf ~' '$(whoami)' 'it'\\''s'")
    #expect(CanvasAgentShell.commandLine(["printf", ""]) == "printf ''")
    #expect(CanvasAgentShell.commandLine([]) == nil)
    #expect(CanvasAgentShell.commandLine([""]) == nil)
    #expect(CanvasAgentShell.commandLine(["echo", "a\nb"]) == nil)
    #expect(CanvasAgentShell.commandLine(Array(repeating: "a", count: 33)) == nil)
}

@Test func agentLaunchBuildsArgumentVectors() {
    #expect(CanvasAgentLaunch.argv(agent: "codex", prompt: nil) == ["codex"])
    #expect(
        CanvasAgentLaunch.argv(agent: "claude", prompt: "Line 1\nLine 2")
            == ["claude", "Line 1 Line 2"])
    #expect(CanvasAgentLaunch.argv(agent: "cursor", prompt: nil) == ["cursor-agent"])
    #expect(CanvasAgentLaunch.argv(agent: "gemini", prompt: "x") == nil)
    #expect(CanvasAgentLaunch.argv(agent: "sh", prompt: nil) == nil)
}

@Test func agentNoteEditsAreMinimalAndBounded() throws {
    let append = try CanvasAgentNoteEditor.edit("# Plan", mode: .append, text: "- step")
    #expect(append.result == "# Plan\n- step")
    #expect(append.location == 6)
    #expect(append.length == 0)
    #expect(append.replacement == "\n- step")
    let prepend = try CanvasAgentNoteEditor.edit("body", mode: .prepend, text: "top")
    #expect(prepend.result == "top\nbody")
    #expect(prepend.location == 0)
    let replace = try CanvasAgentNoteEditor.edit("é old", mode: .replace, text: "new")
    #expect(replace.length == "é old".utf16.count)
    #expect(replace.result == "new")
    let note = "# Plan\nintro\n## Tasks\n- a\n## Done\n"
    let insert = try CanvasAgentNoteEditor.edit(
        note, mode: .insertAfterHeading, text: "- b", heading: "tasks")
    #expect(insert.result == "# Plan\nintro\n## Tasks\n- b\n- a\n## Done\n")
    let last = try CanvasAgentNoteEditor.edit(
        "# End", mode: .insertAfterHeading, text: "tail", heading: "## End")
    #expect(last.result == "# End\ntail\n")
    #expect(throws: CanvasAgentToolError.headingNotFound) {
        try CanvasAgentNoteEditor.edit(note, mode: .insertAfterHeading, text: "x", heading: "Nope")
    }
    #expect(throws: CanvasAgentToolError.headingNotFound) {
        try CanvasAgentNoteEditor.edit(
            "#Tasks", mode: .insertAfterHeading, text: "x", heading: "Tasks")
    }
    #expect(throws: CanvasAgentToolError.noteTooLarge) {
        try CanvasAgentNoteEditor.edit(
            String(repeating: "a", count: 10), mode: .append, text: "bbbb", limit: 12)
    }
    // The edit applies to the UTF-16 view exactly like NSTextView would.
    let base = "🧵 note"
    let edit = try CanvasAgentNoteEditor.edit(base, mode: .append, text: "x")
    let utf16 = Array(base.utf16)
    let rebuilt =
        String(decoding: utf16[..<edit.location], as: UTF16.self) + edit.replacement
        + String(decoding: utf16[(edit.location + edit.length)...], as: UTF16.self)
    #expect(rebuilt == edit.result)
}

@Test func agentNoteSlicesNeverSplitAScalar() {
    let text = "a🧵b" + String(repeating: "c", count: 10)
    let first = CanvasAgentNoteEditor.slice(text, offset: 0, length: 2)
    #expect(first.text == "a🧵")
    #expect(first.total == 13)
    #expect(first.truncated)
    let rest = CanvasAgentNoteEditor.slice(text, offset: 2, length: 100)
    #expect(rest.text == "b" + String(repeating: "c", count: 10))
    #expect(!rest.truncated)
    #expect(CanvasAgentNoteEditor.slice(text, offset: 99, length: 5).text.isEmpty)
}

@Test func agentResultsStayWithinTheirBound() throws {
    var result = CanvasAgentToolResult()
    result.nodes = (0..<100).map { index in
        CanvasAgentNodeSummary(
            id: UUID().uuidString, kind: "Note", title: String(repeating: "t", count: 120),
            x: Double(index), y: 0, width: 380, height: 260, state: "stopped")
    }
    result.edges = (0..<200).map { _ in
        CanvasAgentEdgeSummary(
            id: UUID().uuidString, from: nodeA, to: nodeB, kind: "message",
            label: String(repeating: "l", count: 120), state: "paused")
    }
    let bounded = result.bounded(maximumBytes: 24 * 1_024)
    #expect(try #require(bounded.agentJSON()).count <= 24 * 1_024)
    #expect(bounded.truncated == true)
    var small = CanvasAgentToolResult()
    small.nodes = [result.nodes![0]]
    #expect(small.bounded(maximumBytes: 24 * 1_024) == small)
}

@Test func agentApprovalSummaryNeverShowsNoteBodies() throws {
    let call = try CanvasAgentToolCall.parse(
        tool: "note_write",
        arguments: ["node_id": nodeA, "text": "secret plan body", "mode": "append"])
    let summary = call.approvalSummary.joined(separator: "\n")
    #expect(!summary.contains("secret plan body"))
    #expect(summary.contains("16 bytes"))
    let send = try CanvasAgentToolCall.parse(
        tool: "terminal_send", arguments: ["node_id": nodeA, "command": ["swift", "test"]])
    #expect(send.approvalSummary.contains("Command: swift test"))
}

@Test func agentToolDefinitionsFitInOneMCPFrame() throws {
    let reply: [String: Any] = [
        "jsonrpc": "2.0", "id": 1, "result": ["tools": CanvasAgentToolCatalog.definitions],
    ]
    let data = try JSONSerialization.data(withJSONObject: reply)
    #expect(data.count < 48 * 1_024)
}
