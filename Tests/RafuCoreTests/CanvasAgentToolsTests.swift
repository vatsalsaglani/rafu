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
    #expect(
        throws: CanvasAgentToolError.invalidArgumentReason(
            key: "command", reason: CanvasAgentShellRefusal.controlCharacter(index: 1).reason())
    ) {
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

@Test func typedLineIsBoundedInBytesNotScalars() throws {
    let limit = CanvasAgentToolCall.maximumPromptBytes
    // Two-byte and four-byte scalars: a scalar count would allow twice or four
    // times the byte limit.
    for unit in ["é", "😀"] {
        let long = String(repeating: unit, count: limit)
        let line = CanvasAgentText.singleLine(long, maxBytes: limit)
        #expect(line.utf8.count <= limit)
        #expect(line.utf8.count == limit)
        #expect(line == String(repeating: unit, count: limit / unit.utf8.count))
        #expect(String(validating: Array(line.utf8), as: UTF8.self) == line)
    }
    // A limit inside a scalar cuts before it, never through it.
    let odd = CanvasAgentText.singleLine(String(repeating: "é", count: 10), maxBytes: 5)
    #expect(odd == "éé")
    #expect(CanvasAgentText.singleLine("a\tb\nc", maxBytes: 100) == "a b c")
    #expect(CanvasAgentText.singleLine("short", maxBytes: 100) == "short")
    // The launch prompt uses the same bound.
    let argv = try #require(
        CanvasAgentLaunch.argv(agent: "claude", prompt: String(repeating: "é", count: limit)))
    #expect(argv.last?.utf8.count == limit)
}

@Test func terminalSendTextIsRefusedByBytesNotScalars() throws {
    let limit = CanvasAgentToolCall.maximumPromptBytes
    let fits = String(repeating: "é", count: limit / 2)
    let call = try CanvasAgentToolCall.parse(
        tool: "terminal_send", arguments: ["node_id": nodeA, "text": fits])
    #expect(call.text == fits)
    let over = String(repeating: "é", count: limit / 2 + 1)
    do {
        _ = try CanvasAgentToolCall.parse(
            tool: "terminal_send", arguments: ["node_id": nodeA, "text": over])
        Issue.record("Expected the multibyte text to be refused")
    } catch {
        #expect(error.message.contains("4,098 bytes"))
        #expect(error.message.contains("4,096"))
    }
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

// MARK: Typed-line limits and refusal reasons

@Test func agentShellRefusalNamesTheLimitThatWasHit() {
    #expect(CanvasAgentShell.refusal(for: ["swift", "test"]) == nil)
    #expect(CanvasAgentShell.refusal(for: []) == .empty)
    #expect(CanvasAgentShell.refusal(for: [""]) == .empty)
    #expect(
        CanvasAgentShell.refusal(for: Array(repeating: "a", count: 33))
            == .tooManyArguments(count: 33, limit: 32))
    #expect(CanvasAgentShell.refusal(for: ["echo", "a\nb"]) == .controlCharacter(index: 1))
    #expect(CanvasAgentShell.refusal(for: ["echo", "a\tb"]) == .controlCharacter(index: 1))
    // 32 arguments of 200 bytes pass the per-argument limit and exceed the line.
    let wide = Array(repeating: String(repeating: "a", count: 200), count: 32)
    #expect(CanvasAgentShell.refusal(for: wide) == .lineTooLong(bytes: 32 * 200 + 31, limit: 4_096))
    #expect(CanvasAgentShell.commandLine(wide) == nil)
}

@Test func agentShellArgumentLimitIsNamedAndExact() {
    let limit = CanvasAgentToolCall.maximumCommandArgumentBytes
    #expect(limit == 1_024)
    let fits = String(repeating: "a", count: limit)
    #expect(CanvasAgentShell.refusal(for: ["echo", fits]) == nil)
    #expect(CanvasAgentShell.commandLine(["echo", fits]) != nil)
    let over = String(repeating: "a", count: limit + 1)
    #expect(
        CanvasAgentShell.refusal(for: ["echo", over])
            == .argumentTooLong(index: 1, bytes: limit + 1, limit: limit))
    #expect(CanvasAgentShell.commandLine(["echo", over]) == nil)
}

/// Regression: a ~1,500-byte argument used to fail as a bare `Invalid value for "command".`
@Test func terminalSendCommandOverTheArgumentLimitNamesTheLimit() throws {
    let secret = "SECRET" + String(repeating: "x", count: 1_494)
    let refusal = try #require(CanvasAgentShell.refusal(for: ["echo", secret]))
    #expect(refusal == .argumentTooLong(index: 1, bytes: 1_500, limit: 1_024))
    let reason = refusal.reason()
    #expect(reason.contains("argument 2"))
    #expect(reason.contains("1,500 bytes"))
    #expect(reason.contains("1,024"))
    #expect(reason.contains("4,096"))
    #expect(reason.contains("file or a Rafu note"))
    #expect(!reason.contains("SECRET"))

    do {
        _ = try CanvasAgentToolCall.parse(
            tool: "terminal_send", arguments: ["node_id": nodeA, "command": ["echo", secret]])
        Issue.record("Expected the over-long argument to be refused")
    } catch {
        #expect(error == .invalidArgumentReason(key: "command", reason: reason))
        #expect(error.message.hasPrefix("Invalid value for \"command\": "))
        #expect(!error.message.contains("SECRET"))
    }
}

/// Regression: a 2,500-character prompt used to pass `prompt` validation and
/// then fail as `Invalid value for "command"` after the node was created.
@Test func terminalCreateRefusesALongPromptAsPromptBeforeAnyNodeExists() throws {
    let prompt = (["SECRET line one", String(repeating: "word ", count: 500)])
        .joined(separator: "\n")
    #expect(prompt.utf8.count > 2_500)
    do {
        _ = try CanvasAgentToolCall.parse(
            tool: "terminal_create", arguments: ["agent": "claude", "prompt": prompt])
        Issue.record("Expected the long prompt to be refused")
    } catch {
        guard case .invalidArgumentReason(let key, let reason) = error else {
            Issue.record("Expected a reason, got \(error)")
            return
        }
        #expect(key == "prompt")
        #expect(reason.contains("the prompt is"))
        #expect(reason.contains("1,024 bytes"))
        #expect(reason.contains("file or a Rafu note"))
        #expect(!error.message.contains("SECRET"))
    }
    // A prompt past the 4 KiB field bound gets the same reason.
    #expect(throws: CanvasAgentToolError.self) {
        try CanvasAgentToolCall.parse(
            tool: "terminal_create",
            arguments: ["agent": "codex", "prompt": String(repeating: "a", count: 5_000)])
    }
    let accepted = String(repeating: "a", count: 1_024)
    let call = try CanvasAgentToolCall.parse(
        tool: "terminal_create", arguments: ["agent": "claude", "prompt": accepted])
    #expect(call.prompt == accepted)
}

@Test func terminalSendTextOverTheLimitNamesTheLimit() {
    let text = String(repeating: "a", count: CanvasAgentToolCall.maximumPromptBytes + 1)
    do {
        _ = try CanvasAgentToolCall.parse(
            tool: "terminal_send", arguments: ["node_id": nodeA, "text": text])
        Issue.record("Expected the long text to be refused")
    } catch {
        #expect(error.message.contains("\"text\""))
        #expect(error.message.contains("4,097 bytes"))
        #expect(error.message.contains("4,096"))
    }
}

@Test func terminalSchemasDeclareTheTypedLineLimits() throws {
    func definition(_ name: String) throws -> (String, [String: Any]) {
        let entry = try #require(
            CanvasAgentToolCatalog.definitions.first { $0["name"] as? String == name })
        let schema = try #require(entry["inputSchema"] as? [String: Any])
        return (
            try #require(entry["description"] as? String),
            try #require(schema["properties"] as? [String: Any])
        )
    }
    let (createText, create) = try definition("terminal_create")
    let prompt = try #require(create["prompt"] as? [String: Any])
    #expect(prompt["maxLength"] as? Int == 1_024)
    #expect((prompt["description"] as? String)?.contains("file or a note") == true)
    let command = try #require(create["command"] as? [String: Any])
    let commandText = try #require(command["description"] as? String)
    #expect(commandText.contains("1024 bytes each"))
    #expect(commandText.contains("32 arguments"))
    #expect(create["link"] != nil)
    #expect(createText.contains("link"))
    let (_, send) = try definition("terminal_send")
    let sendCommand = try #require(send["command"] as? [String: Any])
    #expect((sendCommand["description"] as? String)?.contains("1024 bytes each") == true)
}

@Test func terminalCreateLinkParsesOnlyOnTerminalCreate() throws {
    let call = try CanvasAgentToolCall.parse(
        tool: "terminal_create", arguments: ["agent": "claude", "link": true])
    #expect(call.link == true)
    #expect(call.approvalSummary.contains { $0.hasPrefix("Link:") })
    let plain = try CanvasAgentToolCall.parse(tool: "terminal_create", arguments: [:])
    #expect(plain.link == nil)
    #expect(!plain.approvalSummary.contains { $0.hasPrefix("Link:") })
    #expect(throws: CanvasAgentToolError.invalidArgument("link")) {
        try CanvasAgentToolCall.parse(tool: "terminal_create", arguments: ["link": "yes"])
    }
    #expect(throws: CanvasAgentToolError.unexpectedArgument("link")) {
        try CanvasAgentToolCall.parse(
            tool: "terminal_start", arguments: ["node_id": nodeA, "link": true])
    }
    #expect(throws: CanvasAgentToolError.unexpectedArgument("link")) {
        try CanvasAgentToolCall.parse(tool: "note_create", arguments: ["title": "A", "link": true])
    }
}

@Test func agentLaunchRecognisesAKnownAgentProgram() {
    #expect(CanvasAgentLaunch.agent(forCommand: ["claude", "--resume"]) == "claude")
    #expect(CanvasAgentLaunch.agent(forCommand: ["/opt/homebrew/bin/codex"]) == "codex")
    #expect(CanvasAgentLaunch.agent(forCommand: ["cursor-agent"]) == "cursor-agent")
    #expect(CanvasAgentLaunch.agent(forCommand: ["swift", "test"]) == nil)
    #expect(CanvasAgentLaunch.agent(forCommand: []) == nil)
}

@Test func agentToolResultEncodesDeliveryAndMention() throws {
    var result = CanvasAgentToolResult(message: "Queued")
    result.delivered = true
    result.mention = "@helper"
    let text = String(decoding: try #require(result.agentJSON()), as: UTF8.self)
    #expect(text.contains("\"delivered\":true"))
    #expect(text.contains("\"mention\":\"@helper\""))
}

@Test func toolResultCarriesTheNodeStateInSnakeCaseJSON() throws {
    var result = CanvasAgentToolResult(message: "Created.")
    result.state = "stopped"
    let json = String(decoding: try #require(result.agentJSON()), as: UTF8.self)
    #expect(json.contains("\"state\":\"stopped\""))
}

@Test func terminalAndMermaidDescriptionsTeachTheStateAndTheLimit() throws {
    func description(_ name: String) throws -> String {
        let entry = try #require(
            CanvasAgentToolCatalog.definitions.first { $0["name"] as? String == name })
        return try #require(entry["description"] as? String)
    }
    let create = try description("terminal_create")
    #expect(create.contains("state"))
    #expect(create.contains("queued, not typed"))
    #expect(create.contains("link true"))
    #expect(try description("terminal_start").contains("state"))
    #expect(try description("terminal_send").contains("link_set_state"))
    #expect(try description("mermaid_set").contains("8000 by 8000"))
}
