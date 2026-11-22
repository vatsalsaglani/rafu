import Foundation
import Testing

@testable import RafuCore

private func payload(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

private func permissionRequest(
    tool: String, input: [String: Any], event: String = "PermissionRequest"
) throws -> Data {
    try payload([
        "session_id": "s1", "hook_event_name": event, "cwd": "/Users/me/repo",
        "tool_name": tool, "tool_input": input, "permission_mode": "default",
    ])
}

@Suite("Claude permission request summary")
struct AgentPermissionRequestSummaryTests {
    @Test("A Bash request keeps the command and the description")
    func bash() throws {
        let summary = try #require(
            AgentPermissionRequestSummary(
                toolName: "Bash",
                toolInput: ["command": "git status\nls", "description": "Show the state"]))
        #expect(summary.command == "git status\nls")
        #expect(summary.description == "Show the state")
        #expect(summary.filePath == nil)
        #expect(summary.isComplete)
    }

    @Test("A Write carries the full content")
    func writeCarriesTheFullContent() throws {
        let summary = try #require(
            AgentPermissionRequestSummary(
                toolName: "Write",
                toolInput: ["file_path": "/Users/me/repo/a.swift", "content": "let a = 1\n"]))
        #expect(summary.filePath == "/Users/me/repo/a.swift")
        #expect(summary.command == nil)
        #expect(summary.isComplete)
        let change = try #require(summary.fileChanges.first)
        #expect(change.kind == .overwrite)
        #expect(change.body == "let a = 1\n")
        #expect(!change.isDiff)
    }

    @Test("An Edit carries the old and new strings")
    func editCarriesOldAndNewStrings() throws {
        let summary = try #require(
            AgentPermissionRequestSummary(
                toolName: "Edit",
                toolInput: [
                    "file_path": "/r/a.swift", "old_string": "a\nb", "new_string": "c",
                    "replace_all": true,
                ]))
        #expect(summary.isComplete)
        let change = try #require(summary.fileChanges.first)
        #expect(change.kind == .edit)
        #expect(change.isDiff)
        #expect(change.body == "(every match)\n- a\n- b\n+ c")
    }

    @Test("An Edit with an edits array is read")
    func editWithEditsArrayIsRead() throws {
        let summary = try #require(
            AgentPermissionRequestSummary(
                toolName: "Edit",
                toolInput: [
                    "file_path": "/r/a.swift",
                    "edits": [["old_string": "x", "new_string": "y"]],
                ]))
        #expect(summary.isComplete)
        #expect(summary.fileChanges.first?.body == "- x\n+ y")
        // The two forms together are ambiguous: only the terminal answers.
        let both = try #require(
            AgentPermissionRequestSummary(
                toolName: "Edit",
                toolInput: [
                    "file_path": "/r/a.swift", "old_string": "x", "new_string": "y",
                    "edits": [["old_string": "x", "new_string": "y"]],
                ]))
        #expect(!both.isComplete)
    }

    @Test("A MultiEdit carries every edit")
    func multiEditCarriesEveryEdit() throws {
        let summary = try #require(
            AgentPermissionRequestSummary(
                toolName: "MultiEdit",
                toolInput: [
                    "file_path": "/r/a.swift",
                    "edits": [
                        ["old_string": "a", "new_string": "b"],
                        ["old_string": "c", "new_string": ""],
                    ],
                ]))
        #expect(summary.isComplete)
        #expect(summary.fileChanges.first?.body == "- a\n+ b\n\n- c")
    }

    @Test("A body over the limit is cut and incomplete")
    func contentOverTheLimitIsIncomplete() throws {
        let content = String(
            repeating: "a", count: CanvasAgentRequest.Limits.fileChangeBodyBytes + 1)
        let summary = try #require(
            AgentPermissionRequestSummary(
                toolName: "Write", toolInput: ["file_path": "/r/a", "content": content]))
        #expect(!summary.isComplete)
        #expect(
            summary.fileChanges.first?.body.utf8.count
                == CanvasAgentRequest.Limits.fileChangeBodyBytes)
    }

    @Test("An input of an unknown shape is incomplete")
    func editWithoutNewStringIsIncomplete() throws {
        for input: [String: Any] in [
            ["file_path": "/r/a", "old_string": "x"],
            ["file_path": "/r/a", "edits": [["old_string": "x"]]],
            ["file_path": "/r/a", "edits": [String]()],
            ["file_path": "/r/a", "edits": "x"],
        ] {
            let summary = try #require(
                AgentPermissionRequestSummary(toolName: "Edit", toolInput: input))
            #expect(!summary.isComplete)
        }
        let write = try #require(
            AgentPermissionRequestSummary(toolName: "Write", toolInput: ["file_path": "/r/a"]))
        #expect(!write.isComplete)
    }

    @Test("The summary with the largest body fits the spool file")
    func summaryWithTheLargestBodyFitsTheSpoolFile() throws {
        // Worst case for JSON: every character is escaped.
        let quotes = String(repeating: "\"", count: CanvasAgentRequest.Limits.fileChangeBodyBytes)
        let path =
            "/"
            + String(repeating: "\"", count: AgentPermissionRequestSummary.maximumFilePathBytes - 1)
        let event = try AgentHookEvent(
            provider: .claude,
            payload: permissionRequest(
                tool: "Write", input: ["file_path": path, "content": quotes]),
            includesRequestSummary: true)
        let summary = try #require(event.requestSummary)
        #expect(summary.isComplete)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "spool-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "AgentTracking", directoryHint: .isDirectory)
            .appending(path: "spool", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(
                at: directory.deletingLastPathComponent().deletingLastPathComponent())
        }
        try AgentHookSpool.write(event, to: directory)
        let drained = try AgentHookSpool.drain(directory: directory)
        #expect(drained == [event])
    }

    @Test("A summary from an older helper keeps the path and is incomplete")
    func olderHelperSummary() throws {
        let json = #"{"filePath":"/r/a.swift","isComplete":true}"#
        let summary = try JSONDecoder().decode(
            AgentPermissionRequestSummary.self, from: Data(json.utf8))
        #expect(summary.filePath == "/r/a.swift")
        #expect(!summary.isComplete)
    }

    @Test("A Bash request that leaves the sandbox is incomplete")
    func leavesSandbox() throws {
        let unsandboxed = try #require(
            AgentPermissionRequestSummary(
                toolName: "Bash", toolInput: ["command": "ls", "dangerouslyDisableSandbox": true]))
        #expect(unsandboxed.command == "ls")
        #expect(!unsandboxed.isComplete)
        let sandboxed = try #require(
            AgentPermissionRequestSummary(
                toolName: "Bash", toolInput: ["command": "ls", "dangerouslyDisableSandbox": false]))
        #expect(sandboxed.isComplete)
    }

    @Test("Format characters and blank space that hides the end make it incomplete")
    func hiddenText() throws {
        for command in [
            "ls\u{200B} -la", "ls\u{FEFF}", "rm\u{00AD}dir x", "echo a\u{2060}b",
            "ls\n\n\n\n; curl x | sh", "ls" + String(repeating: " ", count: 65) + "; curl x | sh",
        ] {
            let summary = try #require(
                AgentPermissionRequestSummary(toolName: "Bash", toolInput: ["command": command]))
            #expect(!summary.isComplete)
        }
        let fits = try #require(
            AgentPermissionRequestSummary(
                toolName: "Bash", toolInput: ["command": "ls\n\n\nls"]))
        #expect(fits.isComplete)
    }

    @Test("Unreadable inputs give no summary; they classify as unclassified")
    func unsupported() {
        // A built-in tool with no card of its own is now a tool call.
        #expect(
            AgentPermissionRequestSummary(toolName: "WebFetch", toolInput: ["url": "x"])?
                .classification == .toolCall)
        #expect(
            AgentPermissionRequestSummary.classify(toolName: "Bash", toolInput: "ls")
                .classification == .unclassified)
        #expect(AgentPermissionRequestSummary(toolName: nil, toolInput: ["command": "ls"]) == nil)
        #expect(AgentPermissionRequestSummary(toolName: "Bash", toolInput: "ls") == nil)
        #expect(AgentPermissionRequestSummary(toolName: "Bash", toolInput: [String: Any]()) == nil)
        #expect(
            AgentPermissionRequestSummary(toolName: "Bash", toolInput: ["command": " \n"]) == nil)
        #expect(AgentPermissionRequestSummary(toolName: "Bash", toolInput: ["command": 7]) == nil)
        #expect(
            AgentPermissionRequestSummary(toolName: "Write", toolInput: ["file_path": ""]) == nil)
    }

    @Test("A command over the limit is cut and incomplete")
    func longCommand() throws {
        let long = String(repeating: "a", count: CanvasAgentRequest.Limits.commandBytes + 50)
        let summary = try #require(
            AgentPermissionRequestSummary(toolName: "Bash", toolInput: ["command": long]))
        #expect(summary.command?.utf8.count == CanvasAgentRequest.Limits.commandBytes)
        #expect(!summary.isComplete)
    }

    @Test("Control and bidirectional characters are removed and make it incomplete")
    func controlCharacters() throws {
        let command = try #require(
            AgentPermissionRequestSummary(
                toolName: "Bash", toolInput: ["command": "echo\u{1B}[31m hi\u{202E}"]))
        #expect(command.command == "echo[31m hi")
        #expect(!command.isComplete)
        let path = try #require(
            AgentPermissionRequestSummary(
                toolName: "Write", toolInput: ["file_path": "/tmp/a\u{7}b"]))
        #expect(path.filePath == "/tmp/ab")
        #expect(!path.isComplete)
    }

    @Test("A path over the limit is cut and incomplete; the description may be cut alone")
    func longPathAndDescription() throws {
        let path = String(
            repeating: "p", count: AgentPermissionRequestSummary.maximumFilePathBytes + 9)
        let file = try #require(
            AgentPermissionRequestSummary(toolName: "Edit", toolInput: ["file_path": path]))
        #expect(file.filePath?.utf8.count == AgentPermissionRequestSummary.maximumFilePathBytes)
        #expect(!file.isComplete)
        let bash = try #require(
            AgentPermissionRequestSummary(
                toolName: "Bash",
                toolInput: [
                    "command": "ls",
                    "description": String(
                        repeating: "d", count: CanvasAgentRequest.Limits.reasonBytes + 5),
                ]))
        #expect(bash.description?.utf8.count == CanvasAgentRequest.Limits.reasonBytes)
        #expect(bash.isComplete)
    }

    @Test("The helper's answer mode adds the summary; the normal mode never does")
    func eventSummary() throws {
        let data = try permissionRequest(
            tool: "Bash", input: ["command": "ls", "description": "List"])
        let plain = try AgentHookEvent(provider: .claude, payload: data)
        #expect(plain.requestSummary == nil)
        let answering = try AgentHookEvent(
            provider: .claude, payload: data, includesRequestSummary: true)
        #expect(answering.requestSummary?.command == "ls")
        #expect(answering.toolName == "Bash")
        // Only a Claude PermissionRequest carries one.
        let other = try AgentHookEvent(
            provider: .claude,
            payload: permissionRequest(tool: "Bash", input: ["command": "ls"], event: "PreToolUse"),
            includesRequestSummary: true)
        #expect(other.requestSummary == nil)
        let codex = try AgentHookEvent(
            provider: .codex, payload: data, includesRequestSummary: true)
        #expect(codex.requestSummary == nil)
    }

    @Test("The event with its summary round-trips and fits one spool file")
    func roundTripAndSize() throws {
        // Worst case for JSON: every command character is escaped.
        let command = String(repeating: "\"", count: CanvasAgentRequest.Limits.commandBytes)
        let event = try AgentHookEvent(
            provider: .claude,
            payload: permissionRequest(
                tool: "Bash",
                input: [
                    "command": command,
                    "description": String(
                        repeating: "\n", count: CanvasAgentRequest.Limits.reasonBytes),
                ]),
            includesRequestSummary: true)
        let data = try JSONEncoder().encode(event)
        #expect(data.count <= AgentHookSpool.maximumFileBytes)
        #expect(try JSONDecoder().decode(AgentHookEvent.self, from: data) == event)
    }

    @Test("An event from an older helper decodes without a summary")
    func olderEvent() throws {
        let event = try AgentHookEvent(
            provider: .claude, payload: permissionRequest(tool: "Bash", input: ["command": "ls"]))
        let data = try JSONEncoder().encode(event)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["requestSummary"] == nil)
        #expect(try JSONDecoder().decode(AgentHookEvent.self, from: data).requestSummary == nil)
    }

    @Test("Decoding rejects a summary the sanitizer would change")
    func decodeRejectsUnclean() throws {
        func decode(_ json: String) -> AgentPermissionRequestSummary? {
            try? JSONDecoder().decode(AgentPermissionRequestSummary.self, from: Data(json.utf8))
        }
        #expect(decode(#"{"command":"ls","isComplete":true}"#)?.command == "ls")
        #expect(decode(#"{"command":"l\u0007s","isComplete":true}"#) == nil)
        // A summary may claim less than the sanitizer finds, never more.
        #expect(decode(#"{"command":"l\u0007s","isComplete":false}"#) == nil)
        #expect(decode(#"{"command":"ls","isComplete":false}"#)?.isComplete == false)
        #expect(decode(#"{"isComplete":true}"#) == nil)
    }

    // MARK: MCP tools

    private static let atlassian = "mcp__claude_ai_Atlassian_MCP__atlassianUserInfo"

    @Test("An MCP tool with no arguments is complete and names its server and tool")
    func mcpToolWithEmptyInput() throws {
        let summary = try #require(
            AgentPermissionRequestSummary(toolName: Self.atlassian, toolInput: [String: Any]()))
        #expect(summary.isComplete)
        #expect(summary.command == nil)
        #expect(summary.filePath == nil)
        let call = try #require(summary.toolCall)
        #expect(call.name == Self.atlassian)
        #expect(call.server == "claude_ai_Atlassian_MCP")
        #expect(call.tool == "atlassianUserInfo")
        #expect(call.arguments == "{}")
        #expect(
            call.reasonLine == "Atlassian MCP (claude.ai): atlassianUserInfo\n" + Self.atlassian)
        // An absent input counts as an empty object.
        let absent = try #require(
            AgentPermissionRequestSummary(toolName: Self.atlassian, toolInput: nil))
        #expect(absent.toolCall?.arguments == "{}")
    }

    @Test("Only a server with the claude.ai prefix gets the claude.ai label")
    func mcpServerLabel() throws {
        #expect(
            AgentPermissionRequestSummary.friendlyServer("claude_ai_Atlassian_MCP")
                == "Atlassian MCP (claude.ai)")
        #expect(AgentPermissionRequestSummary.friendlyServer("github") == "github")
        #expect(AgentPermissionRequestSummary.friendlyServer("claude_ai_") == "claude_ai_")
        let identity = try #require(
            AgentPermissionRequestSummary.toolIdentity(
                fromReason: AgentPermissionRequestSummary.toolReason(name: "mcp__github__search")
                    ?? ""))
        #expect(identity.server == "github")
        #expect(identity.tool == "search")
        #expect(identity.name == "mcp__github__search")
        // Text that was not built by toolReason has no identity.
        #expect(
            AgentPermissionRequestSummary.toolIdentity(
                fromReason: "Atlassian: tool\nmcp__github__search") == nil)
        #expect(AgentPermissionRequestSummary.toolIdentity(fromReason: "one line") == nil)
    }

    @Test("MCP arguments are sorted, pretty, stable JSON text")
    func mcpArgumentsAreStable() throws {
        let input: [String: Any] = [
            "query": "project = A/B", "limit": 5, "nested": ["z": 1, "a": [true, NSNull()]],
        ]
        let first = try #require(
            AgentPermissionRequestSummary(toolName: "mcp__jira__search", toolInput: input))
        let second = try #require(
            AgentPermissionRequestSummary(toolName: "mcp__jira__search", toolInput: input))
        #expect(first == second)
        let text = try #require(first.toolCall?.arguments)
        #expect(first.isComplete)
        // Sorted keys, and a slash is not escaped.
        let limit = try #require(text.range(of: "\"limit\""))
        let nested = try #require(text.range(of: "\"nested\""))
        let query = try #require(text.range(of: "\"query\""))
        #expect(limit.lowerBound < nested.lowerBound && nested.lowerBound < query.lowerBound)
        #expect(text.contains("project = A/B"))
        // What is shown is valid JSON that holds the same value.
        let back = try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(back["limit"] as? Int == 5)
    }

    @Test("A line break in an argument shows as an escape and stays complete")
    func mcpLineBreakIsEscaped() throws {
        let summary = try #require(
            AgentPermissionRequestSummary(
                toolName: "mcp__jira__comment", toolInput: ["body": "a\nb\u{1}c"]))
        let text = try #require(summary.toolCall?.arguments)
        #expect(summary.isComplete)
        #expect(text.contains(#"a\nb\u0001c"#))
    }

    @Test("MCP arguments over the limit, or with a hidden character, are incomplete")
    func mcpArgumentsThatCannotShowWhole() throws {
        let long = String(repeating: "a", count: CanvasAgentRequest.Limits.commandBytes)
        let tooLong = try #require(
            AgentPermissionRequestSummary(toolName: "mcp__x__y", toolInput: ["q": long]))
        #expect(!tooLong.isComplete)
        #expect(
            (tooLong.toolCall?.arguments.utf8.count ?? .max)
                <= CanvasAgentRequest.Limits.commandBytes)
        let bidi = try #require(
            AgentPermissionRequestSummary(
                toolName: "mcp__x__y", toolInput: ["q": "safe\u{202E}evil"]))
        #expect(!bidi.isComplete)
        #expect(bidi.toolCall?.arguments.contains("\u{202E}") == false)
        // Deep nesting makes a run of blank space that could hide the end.
        var deep: Any = "end"
        for _ in 0..<40 { deep = ["k": deep] }
        let nested = try #require(
            AgentPermissionRequestSummary(toolName: "mcp__x__y", toolInput: ["d": deep]))
        #expect(!nested.isComplete)
    }

    @Test("A name that is not mcp__server__tool in the strict form gives no summary")
    func mcpBadNames() {
        let tooLong = "mcp__s__" + String(repeating: "t", count: 200)
        for name in [
            "mcp__", "mcp__x", "mcp____tool", "mcp__server__", "mcp__a b__tool", "mcp__a/b__tool",
            "mcp__srv__to\u{202E}ol", "mcp__srv__tool\n", "MCP__a__b", "mcp_a__b", tooLong,
        ] {
            #expect(
                AgentPermissionRequestSummary(toolName: name, toolInput: [String: Any]()) == nil,
                "\(name)")
        }
        #expect(
            AgentPermissionRequestSummary(toolName: "mcp__a__b.c-d_e", toolInput: nil) != nil)
        // Only the first double underscore splits the name.
        #expect(AgentPermissionRequestSummary.mcpParts(of: "mcp__a__b__c")?.tool == "b__c")
    }

    @Test("A non-object tool input gives no MCP summary")
    func mcpNonObjectInput() {
        #expect(AgentPermissionRequestSummary(toolName: "mcp__x__y", toolInput: "text") == nil)
        #expect(AgentPermissionRequestSummary(toolName: "mcp__x__y", toolInput: [1, 2]) == nil)
        #expect(AgentPermissionRequestSummary(toolName: "mcp__x__y", toolInput: NSNull()) == nil)
    }

    @Test("An MCP summary round-trips, and a decoded one that is not sanitized is rejected")
    func mcpCodable() throws {
        let summary = try #require(
            AgentPermissionRequestSummary(toolName: "mcp__jira__search", toolInput: ["q": "x"]))
        let data = try JSONEncoder().encode(summary)
        #expect(try JSONDecoder().decode(AgentPermissionRequestSummary.self, from: data) == summary)
        func decode(_ json: String) -> AgentPermissionRequestSummary? {
            try? JSONDecoder().decode(AgentPermissionRequestSummary.self, from: Data(json.utf8))
        }
        #expect(
            decode(#"{"toolCall":{"name":"mcp__a__b","arguments":"{}"},"isComplete":true}"#) != nil)
        // An unclean argument text, a bad name, or a command beside a tool call.
        #expect(
            decode(#"{"toolCall":{"name":"mcp__a__b","arguments":"{\u0007}"},"isComplete":true}"#)
                == nil)
        #expect(
            decode(#"{"toolCall":{"name":"Bash","arguments":"{}"},"isComplete":true}"#) == nil)
        #expect(
            decode(
                #"{"command":"ls","toolCall":{"name":"mcp__a__b","arguments":"{}"},"isComplete":true}"#
            ) == nil)
        // It may claim less than the sanitizer finds, never more.
        let wide = String(repeating: "a", count: CanvasAgentRequest.Limits.commandBytes + 1)
        #expect(
            decode(#"{"toolCall":{"name":"mcp__a__b","arguments":"\#(wide)"},"isComplete":true}"#)
                == nil)
    }

    @Test("The helper's answer mode adds an MCP summary; the normal mode never does")
    func mcpEventSummary() throws {
        let data = try permissionRequest(tool: Self.atlassian, input: [:])
        let plain = try AgentHookEvent(provider: .claude, payload: data)
        #expect(plain.requestSummary == nil)
        let answering = try AgentHookEvent(
            provider: .claude, payload: data, includesRequestSummary: true)
        #expect(answering.requestSummary?.toolCall?.name == Self.atlassian)
        let codex = try AgentHookEvent(
            provider: .codex, payload: data, includesRequestSummary: true)
        #expect(codex.requestSummary == nil)
        // The event with its summary fits one spool file, also with the most arguments.
        let wide = try AgentHookEvent(
            provider: .claude,
            payload: permissionRequest(
                tool: Self.atlassian,
                input: ["q": String(repeating: "\"", count: CanvasAgentRequest.Limits.commandBytes)]
            ), includesRequestSummary: true)
        let encoded = try JSONEncoder().encode(wide)
        #expect(encoded.count <= AgentHookSpool.maximumFileBytes)
        #expect(try JSONDecoder().decode(AgentHookEvent.self, from: encoded) == wide)
    }

    // MARK: Classification

    @Test("Every request gets a class; nothing is dropped without one")
    func classes() {
        func kind(_ name: String?, _ input: Any? = [String: Any]()) -> String {
            AgentPermissionRequestSummary.classify(toolName: name, toolInput: input)
                .classification.rawValue
        }
        #expect(kind("Bash", ["command": "ls"]) == "command")
        #expect(kind("Write", ["file_path": "/a", "content": "x"]) == "fileChange")
        #expect(kind("mcp__a__b") == "toolCall")
        #expect(kind("WebFetch", ["url": "https://example.com"]) == "toolCall")
        #expect(kind("AskUserQuestion", ["questions": []]) == "questions")
        #expect(kind("ExitPlanMode", ["plan": "p"]) == "plan")
        #expect(kind(nil) == "unclassified")
        #expect(kind("bad name!") == "unclassified")
        #expect(kind("WebFetch", "not an object") == "unclassified")
        #expect(kind("AskUserQuestion", [1]) == "unclassified")
    }

    @Test("A built-in tool name has the strict form and cannot pose as an MCP name")
    func builtInNames() {
        for name in ["Read", "WebFetch", "propose_skills", "a", String(repeating: "A", count: 64)] {
            #expect(AgentPermissionRequestSummary.isBuiltInToolName(name), "\(name)")
        }
        for name in [
            "", "1Read", "Web Fetch", "Read\n", "MCP__a__b", "mcp_a__b", "Re\u{202E}ad",
            String(repeating: "A", count: 65), "Read.x", "Read-x",
        ] {
            #expect(!AgentPermissionRequestSummary.isBuiltInToolName(name), "\(name)")
        }
        // A question, a plan or a command never becomes a plain tool card:
        // a plain allow is not a valid answer for the first two.
        for name in ["AskUserQuestion", "ExitPlanMode", "Bash", "Edit", "MultiEdit", "Write"] {
            #expect(
                AgentPermissionRequestSummary.classification(forToolName: name) != .toolCall)
            #expect(AgentPermissionRequestSummary(toolName: name, arguments: "{}") == nil)
        }
    }

    @Test("A built-in tool card names the tool on both reason lines and shows every argument")
    func builtInToolCall() throws {
        let summary = try #require(
            AgentPermissionRequestSummary(
                toolName: "WebFetch", toolInput: ["url": "https://example.com", "prompt": "Sum"]))
        let call = try #require(summary.toolCall)
        #expect(call.isBuiltIn)
        #expect(call.server == "")
        #expect(call.tool == "WebFetch")
        #expect(call.reasonLine == "Claude Code tool: WebFetch\nWebFetch")
        #expect(call.arguments.contains("https://example.com"))
        #expect(call.arguments.contains("\"prompt\" : \"Sum\""))
        #expect(summary.isComplete)
        let identity = try #require(
            AgentPermissionRequestSummary.toolIdentity(fromReason: call.reasonLine))
        #expect(identity.server == "Claude Code tool")
        #expect(identity.tool == "WebFetch")
        // Answered from Up next through the generic tool card.
        #expect(summary.waitsForAnswer)
        let mcp = try #require(
            AgentPermissionRequestSummary(toolName: "mcp__a__b", toolInput: [String: Any]()))
        #expect(mcp.waitsForAnswer)
        // A built-in summary round-trips.
        let data = try JSONEncoder().encode(summary)
        #expect(try JSONDecoder().decode(AgentPermissionRequestSummary.self, from: data) == summary)
    }

    @Test("An AskUserQuestion input gives its questions, keyed by index")
    func questions() throws {
        let summary = AgentPermissionRequestSummary.classify(
            toolName: "AskUserQuestion",
            toolInput: [
                "questions": [
                    [
                        "question": "Which framework?", "header": "Framework",
                        "options": [
                            ["label": "React", "description": "Library", "preview": "<div/>"],
                            ["label": "Vue", "description": "Progressive"],
                        ],
                        "multiSelect": false,
                    ],
                    [
                        "question": "Which parts?", "header": "Parts",
                        "options": [["label": "Intro"], ["label": "End"]],
                        "multiSelect": true,
                    ],
                ]
            ])
        #expect(summary.classification == .questions)
        #expect(summary.isComplete)
        // The terminal question stays on screen while the hook waits.
        #expect(summary.waitsForAnswer)
        #expect(summary.questions.map(\.id) == ["0", "1"])
        let first = summary.questions[0]
        #expect(first.text == "Which framework?")
        #expect(first.header == "Framework")
        #expect(first.choices.map(\.label) == ["React", "Vue"])
        #expect(first.choices[0].preview == "<div/>")
        #expect(first.choices[1].preview == nil)
        #expect(!first.allowsMultiple)
        #expect(first.allowsFreeText)
        #expect(summary.questions[1].allowsMultiple)
        #expect(first.accepts("React"))
        #expect(first.accepts(QuestionAnswer(text: "Svelte")))
        #expect(!first.accepts(QuestionAnswer(labels: ["React", "Vue"])))
        #expect(summary.questions[1].accepts(QuestionAnswer(labels: ["Intro", "End"])))
        // The summary round-trips.
        let data = try JSONEncoder().encode(summary)
        #expect(try JSONDecoder().decode(AgentPermissionRequestSummary.self, from: data) == summary)
    }

    @Test("Questions that the answer could not name exactly need the terminal")
    func questionLimits() {
        func summary(_ questions: Any) -> AgentPermissionRequestSummary {
            AgentPermissionRequestSummary.classify(
                toolName: "AskUserQuestion", toolInput: ["questions": questions])
        }
        let ok: [String: Any] = ["question": "Q?", "options": [["label": "A"]]]
        // Two questions with one text: Claude Code keys answers by text.
        let twice = summary([ok, ok])
        #expect(!twice.isComplete)
        #expect(twice.questions.allSatisfy { $0.terminalOnly })
        // A multi-select label with ", " would make the joined answer ambiguous.
        let comma = summary([
            ["question": "Q?", "multiSelect": true, "options": [["label": "a, b"]]]
        ])
        #expect(!comma.isComplete)
        // Five questions, none, a missing text, a label that is not text.
        #expect(!summary(Array(repeating: ok, count: 5)).isComplete)
        #expect(!summary([Any]()).isComplete)
        #expect(!summary([["options": [["label": "A"]]]]).isComplete)
        #expect(!summary([["question": "Q?", "options": [["label": 1]]]]).isComplete)
        // A question text the sanitizer changes.
        #expect(!summary([["question": "Q\u{202E}?", "options": [["label": "A"]]]]).isComplete)
    }

    @Test("Previews past the total budget are dropped, the questions stay answerable")
    func previewBudget() {
        let preview = String(repeating: "p", count: CanvasAgentRequest.Limits.previewBytes)
        let options = (0..<6).map { ["label": "L\($0)", "preview": preview] }
        let questions = (0..<4).map { ["question": "Q\($0)?", "options": options] }
        let summary = AgentPermissionRequestSummary.classify(
            toolName: "AskUserQuestion", toolInput: ["questions": questions])
        let kept = summary.questions.flatMap(\.choices).compactMap(\.preview)
        #expect(
            kept.reduce(0) { $0 + $1.utf8.count }
                <= AgentPermissionRequestSummary.maximumPreviewBytesTotal)
        #expect(summary.isComplete)
    }

    @Test("An ExitPlanMode input gives the plan and its path, cut and marked when long")
    func plan() throws {
        let summary = AgentPermissionRequestSummary.classify(
            toolName: "ExitPlanMode",
            toolInput: ["plan": "## Plan\n1. Do", "planFilePath": "/tmp/plan.md"])
        #expect(summary.classification == .plan)
        #expect(summary.plan == .init(path: "/tmp/plan.md", text: "## Plan\n1. Do"))
        #expect(summary.isComplete)
        #expect(!summary.waitsForAnswer)
        let long = AgentPermissionRequestSummary.classify(
            toolName: "ExitPlanMode",
            toolInput: [
                "plan": String(repeating: "x", count: CanvasAgentRequest.Limits.planBytes + 9)
            ])
        #expect(long.plan?.text.utf8.count == CanvasAgentRequest.Limits.planBytes)
        #expect(!long.isComplete)
        let data = try JSONEncoder().encode(summary)
        #expect(try JSONDecoder().decode(AgentPermissionRequestSummary.self, from: data) == summary)
    }

    @Test("An unclassified request keeps only its sanitized name and a notice line")
    func unclassified() throws {
        let summary = AgentPermissionRequestSummary.classify(
            toolName: "odd tool\u{7}", toolInput: ["secret": "value"])
        #expect(summary.classification == .unclassified)
        #expect(summary.unclassifiedToolName == "odd tool")
        #expect(!summary.isComplete)
        #expect(!summary.waitsForAnswer)
        #expect(
            summary.noticeReason == "Claude Code asks to use odd tool. Open the terminal to answer."
        )
        let data = try JSONEncoder().encode(summary)
        #expect(!String(decoding: data, as: UTF8.self).contains("value"))
        #expect(try JSONDecoder().decode(AgentPermissionRequestSummary.self, from: data) == summary)
        #expect(
            AgentPermissionRequestSummary.classify(toolName: nil, toolInput: nil).noticeReason
                == "Claude Code asks for permission. Open the terminal to answer.")
        #expect(
            AgentPermissionRequestSummary(toolName: "Bash", toolInput: [:])?.noticeReason == nil)
    }

    @Test("Decoding rejects a class with fields of another class")
    func decodeRejectsMixedClasses() {
        func decode(_ json: String) -> AgentPermissionRequestSummary? {
            try? JSONDecoder().decode(AgentPermissionRequestSummary.self, from: Data(json.utf8))
        }
        #expect(decode(#"{"classification":"unclassified","isComplete":false}"#) != nil)
        #expect(decode(#"{"classification":"unclassified","isComplete":true}"#) == nil)
        #expect(
            decode(#"{"classification":"unclassified","command":"ls","isComplete":false}"#)
                == nil)
        #expect(decode(#"{"classification":"plan","isComplete":false}"#) == nil)
        #expect(
            decode(#"{"classification":"plan","plan":{"text":"a\u0007"},"isComplete":false}"#)
                == nil)
        #expect(decode(#"{"classification":"questions","isComplete":false}"#) == nil)
        #expect(decode(#"{"classification":"fileChange","command":"ls","isComplete":true}"#) == nil)
        // An older helper sends no classification.
        #expect(decode(#"{"command":"ls","isComplete":true}"#)?.classification == .command)
    }

    // MARK: Permission suggestions

    private static var suggestion: [String: Any] {
        [
            "type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "npm test"]],
            "behavior": "allow", "destination": "localSettings",
        ]
    }

    @Test("One understood suggestion is kept with its exact effect")
    func permissionSuggestion() throws {
        let summary = try #require(
            AgentPermissionRequestSummary(
                toolName: "Bash", toolInput: ["command": "npm test"],
                permissionSuggestions: [Self.suggestion]))
        let kept = try #require(summary.permissionSuggestion)
        #expect(kept.rule == "Bash(npm test)")
        #expect(kept.line == "Add rule Bash(npm test) to local settings")
        let data = try JSONEncoder().encode(summary)
        #expect(try JSONDecoder().decode(AgentPermissionRequestSummary.self, from: data) == summary)
        let whole = AgentPermissionRequestSummary.PermissionSuggestion(entries: [
            [
                "type": "addRules", "rules": [["toolName": "WebSearch"]], "behavior": "allow",
                "destination": "session",
            ]
        ])
        #expect(whole?.line == "Add rule WebSearch to this session")
    }

    @Test("Any suggestion Rafu cannot show whole is not offered")
    func permissionSuggestionRefused() {
        func understood(_ entries: Any?) -> Bool {
            AgentPermissionRequestSummary.PermissionSuggestion(entries: entries) != nil
        }
        var extra = Self.suggestion
        extra["mode"] = "auto"
        var deny = Self.suggestion
        deny["behavior"] = "deny"
        var twoRules = Self.suggestion
        twoRules["rules"] = [["toolName": "Bash"], ["toolName": "Read"]]
        var badName = Self.suggestion
        badName["rules"] = [["toolName": "Bash X"]]
        var badContent = Self.suggestion
        badContent["rules"] = [["toolName": "Bash", "ruleContent": "a\u{202E}b"]]
        var unknownDestination = Self.suggestion
        unknownDestination["destination"] = "managedSettings"
        for entries: Any? in [
            nil, [Any](), [Self.suggestion, Self.suggestion], [extra], [deny], [twoRules],
            [badName], [badContent], [unknownDestination],
            [["type": "setMode", "mode": "acceptEdits", "destination": "session"]],
        ] {
            #expect(!understood(entries))
        }
        // A file change or a question set never carries one.
        let write = AgentPermissionRequestSummary.classify(
            toolName: "Write", toolInput: ["file_path": "/a", "content": "x"],
            permissionSuggestions: [Self.suggestion])
        #expect(write.permissionSuggestion == nil)
    }
}
