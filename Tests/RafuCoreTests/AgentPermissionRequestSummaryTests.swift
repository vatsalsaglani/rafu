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

    @Test("Edit, MultiEdit and Write keep only the file path")
    func files() throws {
        for tool in ["Edit", "MultiEdit", "Write"] {
            let summary = try #require(
                AgentPermissionRequestSummary(
                    toolName: tool,
                    toolInput: [
                        "file_path": "/Users/me/repo/a.swift", "content": "secret body",
                        "old_string": "old secret", "new_string": "new secret",
                    ]))
            #expect(summary.filePath == "/Users/me/repo/a.swift")
            #expect(summary.command == nil)
            #expect(summary.description == nil)
            #expect(summary.isComplete)
            let encoded = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
            #expect(!encoded.contains("secret"))
        }
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
