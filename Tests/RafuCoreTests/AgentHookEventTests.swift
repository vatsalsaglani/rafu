import Foundation
import RafuCore
import Testing

private func payload(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

@Suite("Agent hook event normalization")
struct AgentHookEventTests {
    @Test("A Claude Stop keeps identity, folder, and a bounded reply preview")
    func claudeStop() throws {
        let long = String(repeating: "a", count: 900)
        let event = try AgentHookEvent(
            provider: .claude,
            payload: payload([
                "session_id": "s1", "hook_event_name": "Stop", "cwd": "/Users/me/repo",
                "last_assistant_message": "Done\n" + long, "prompt": "secret prompt",
                "transcript_path": "/tmp/t.jsonl",
            ]))
        #expect(event.provider == .claude)
        #expect(event.sessionID == "s1")
        #expect(event.hookEventName == "Stop")
        #expect(event.cwd == "/Users/me/repo")
        #expect(event.lastAssistantMessage?.count == AgentHookEvent.maximumMessageLength)
        #expect(event.lastAssistantMessage?.hasPrefix("Done\n") == true)
        #expect(event.sessionKey == "claude:s1")
        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        #expect(!encoded.contains("secret prompt"))
        #expect(!encoded.contains("t.jsonl"))
    }

    @Test("Tool, notification, and tool-use ids are kept; control characters are not")
    func fields() throws {
        let event = try AgentHookEvent(
            provider: .claude,
            payload: payload([
                "session_id": "s\u{7}2", "hook_event_name": "Notification",
                "notification_type": "permission_prompt", "tool_name": "Bash",
                "tool_use_id": "toolu_1", "tool_input": ["command": "rm -rf /"],
            ]))
        #expect(event.sessionID == "s2")
        #expect(event.notificationType == "permission_prompt")
        #expect(event.toolName == "Bash")
        #expect(event.toolUseID == "toolu_1")
        #expect(event.lastAssistantMessage == nil)
    }

    @Test("A message is kept only for Stop")
    func messageOnlyForStop() throws {
        let event = try AgentHookEvent(
            provider: .codex,
            payload: payload([
                "session_id": "c1", "hook_event_name": "PreToolUse",
                "last_assistant_message": "should not be kept",
            ]))
        #expect(event.lastAssistantMessage == nil)
    }

    @Test("Unknown events, missing sessions, and non-objects are refused")
    func refusals() throws {
        #expect(throws: AgentHookEventError.unknownEvent) {
            try AgentHookEvent(
                provider: .claude,
                payload: try payload(["session_id": "s", "hook_event_name": "PreCompact"]))
        }
        #expect(throws: AgentHookEventError.unknownEvent) {
            try AgentHookEvent(
                provider: .codex,
                payload: try payload(["session_id": "s", "hook_event_name": "Notification"]))
        }
        #expect(throws: AgentHookEventError.missingSession) {
            try AgentHookEvent(
                provider: .claude, payload: try payload(["hook_event_name": "Stop"]))
        }
        #expect(throws: AgentHookEventError.notAnObject) {
            try AgentHookEvent(provider: .claude, payload: Data("[1,2]".utf8))
        }
        #expect(throws: AgentHookEventError.payloadTooLarge) {
            try AgentHookEvent(
                provider: .claude,
                payload: Data(count: AgentHookEvent.maximumPayloadBytes + 1))
        }
    }

    @Test("Cursor names map to the shared names")
    func cursor() throws {
        let stop = try AgentHookEvent(
            provider: .cursor,
            payload: payload([
                "hook_event_name": "stop", "status": "completed", "conversation_id": "k1",
                "workspace_roots": ["/w"],
            ]))
        #expect(stop.hookEventName == "Stop")
        #expect(stop.sessionID == "k1")
        #expect(stop.cwd == "/w")
        let aborted = try AgentHookEvent(
            provider: .cursor,
            payload: payload([
                "hook_event_name": "stop", "status": "aborted", "conversation_id": "k1",
            ]))
        #expect(aborted.hookEventName == "Interrupt")
        let response = try AgentHookEvent(
            provider: .cursor,
            payload: payload([
                "hook_event_name": "afterAgentResponse", "text": "Hello",
                "conversation_id": "k1",
            ]))
        #expect(response.hookEventName == "AgentResponse")
        #expect(response.lastAssistantMessage == "Hello")
    }

    @Test("The event round-trips through the spool file format")
    func roundTrip() throws {
        let event = AgentHookEvent(
            provider: .codex, sessionID: "c", hookEventName: "Stop", cwd: "/r",
            lastAssistantMessage: "ok", ancestorProcessIDs: [10, 9, 1],
            time: Date(timeIntervalSince1970: 100))
        let decoded = try JSONDecoder().decode(
            AgentHookEvent.self, from: try JSONEncoder().encode(event))
        #expect(decoded == event)
        #expect(decoded.schemaVersion == AgentHookEvent.currentSchemaVersion)
    }
}

@Suite("Agent hook spool")
struct AgentHookSpoolTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "rafu-spool-\(UUID().uuidString)")
            .appending(path: "AgentTracking", directoryHint: .isDirectory)
            .appending(path: "spool", directoryHint: .isDirectory)
        return root
    }

    @Test("Write then drain: private permissions, oldest first, files deleted")
    func writeAndDrain() throws {
        let spool = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: spool.deletingLastPathComponent()) }
        let first = AgentHookEvent(
            provider: .claude, sessionID: "a", hookEventName: "UserPromptSubmit",
            time: Date(timeIntervalSince1970: 10))
        let second = AgentHookEvent(
            provider: .claude, sessionID: "a", hookEventName: "Stop",
            time: Date(timeIntervalSince1970: 20))
        try AgentHookSpool.write(second, to: spool)
        try AgentHookSpool.write(first, to: spool)
        let directoryMode =
            (try FileManager.default.attributesOfItem(atPath: spool.path)[.posixPermissions]
            as? NSNumber)?.intValue
        #expect(directoryMode == 0o700)
        let file = spool.appending(path: first.id.uuidString + ".json")
        let fileMode =
            (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
            as? NSNumber)?.intValue
        #expect(fileMode == 0o600)
        let events = try AgentHookSpool.drain(directory: spool)
        #expect(events.map(\.id) == [first.id, second.id])
        #expect(try FileManager.default.contentsOfDirectory(atPath: spool.path).isEmpty)
    }

    @Test("Drain deletes invalid files and respects its limit")
    func drainLimitAndGarbage() throws {
        let spool = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: spool.deletingLastPathComponent()) }
        for index in 0..<5 {
            try AgentHookSpool.write(
                AgentHookEvent(
                    provider: .codex, sessionID: "s\(index)", hookEventName: "SessionStart"),
                to: spool)
        }
        try Data("not json".utf8).write(to: spool.appending(path: "garbage.json"))
        let firstBatch = try AgentHookSpool.drain(directory: spool, limit: 3)
        #expect(firstBatch.count <= 3)
        let rest = try AgentHookSpool.drain(directory: spool, limit: 100)
        #expect(firstBatch.count + rest.count == 5)
        #expect(try FileManager.default.contentsOfDirectory(atPath: spool.path).isEmpty)
    }

    @Test("A missing spool drains to nothing")
    func missingSpool() throws {
        let spool = try temporaryRoot()
        #expect(try AgentHookSpool.drain(directory: spool).isEmpty)
    }

    @Test("The helper accepts only an absolute AgentTracking/spool directory")
    func spoolArgumentShape() {
        #expect(
            AgentTrackingPaths.isSpoolDirectory(
                URL(
                    fileURLWithPath:
                        "/Users/me/Library/Application Support/Rafu/AgentTracking/spool")
            ))
        #expect(!AgentTrackingPaths.isSpoolDirectory(URL(fileURLWithPath: "/tmp/elsewhere")))
        #expect(
            !AgentTrackingPaths.isSpoolDirectory(
                URL(fileURLWithPath: "/x/AgentTracking/spool/../../etc")))
    }

    @Test("Paths live below the identity's Application Support folder")
    func paths() {
        let base = URL(fileURLWithPath: "/Users/me/Library/Application Support")
        let paths = AgentTrackingPaths(identity: .lightning, baseDirectory: base)
        #expect(
            paths.spool.path
                == "/Users/me/Library/Application Support/Rafu Lightning/AgentTracking/spool")
        #expect(paths.helper.lastPathComponent == AgentTrackingPaths.helperName)
    }
}
