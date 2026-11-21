import Foundation
import RafuCore
import Testing

@testable import RafuApp

private func event(
    tool: String, input: [String: Any], name: String = "PermissionRequest",
    includesSummary: Bool = true, provider: AgentHookProvider = .claude
) throws -> AgentHookEvent {
    let payload = try JSONSerialization.data(withJSONObject: [
        "session_id": "s1", "hook_event_name": name, "cwd": "/Users/me/repo",
        "tool_name": tool, "tool_input": input,
    ])
    return try AgentHookEvent(
        provider: provider, payload: payload, includesRequestSummary: includesSummary)
}

private func temporaryBridge() throws -> (bridge: ClaudePermissionAnswerBridge, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "rafu-bridge-\(UUID().uuidString)", directoryHint: .isDirectory)
    let spool = root.appending(path: "AgentTracking", directoryHint: .isDirectory)
        .appending(path: "spool", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
    return (ClaudePermissionAnswerBridge(channel: AgentAnswerChannel(spool: spool)), root)
}

@Suite("Claude permission answer bridge")
struct ClaudePermissionAnswerBridgeTests {
    @Test("A Bash request becomes a command request keyed by the event id")
    func bash() throws {
        let hook = try event(
            tool: "Bash", input: ["command": "swift build", "description": "Build it"])
        let request = try #require(ClaudePermissionAnswerBridge.request(for: hook))
        #expect(request.key == hook.id)
        #expect(request.kind == .command)
        #expect(request.command == "swift build")
        #expect(request.reason == "Build it")
        #expect(request.cwd == "/Users/me/repo")
        #expect(!request.terminalOnly)
        #expect(request.receivedAt == hook.time)
    }

    @Test("A command request offers Run, Deny and Deny and stop, and no session grant")
    func commandOptions() throws {
        let request = try #require(
            ClaudePermissionAnswerBridge.request(
                for: try event(tool: "Bash", input: ["command": "ls"])))
        #expect(request.options.map(\.label) == ["Run", "Deny", "Deny and stop"])
        #expect(!request.permits(.acceptForSession))
        #expect(request.permits(.accept))
        #expect(request.permits(.cancel))
    }

    @Test("A file change request carries the content and is answerable")
    func theFileChangeRequestCarriesTheContent() throws {
        let write = try #require(
            ClaudePermissionAnswerBridge.request(
                for: try event(
                    tool: "Write",
                    input: ["file_path": "/Users/me/repo/a.swift", "content": "body"])))
        #expect(write.kind == .fileChange)
        #expect(write.command == nil)
        #expect(write.reason == "Change file: /Users/me/repo/a.swift")
        #expect(!write.terminalOnly)
        #expect(write.fileChanges.first?.body == "body")
        #expect(write.fileChanges.first?.kind == .overwrite)
        #expect(
            write.options.map(\.label) == ["Allow", "Deny", "Deny and stop"])
        let edit = try #require(
            ClaudePermissionAnswerBridge.request(
                for: try event(
                    tool: "Edit",
                    input: ["file_path": "/r/a.swift", "old_string": "a", "new_string": "b"])))
        #expect(!edit.terminalOnly)
        #expect(edit.fileChanges.first?.body == "- a\n+ b")
        // A tool input of a shape Rafu does not know stays in the terminal.
        let odd = try #require(
            ClaudePermissionAnswerBridge.request(
                for: try event(tool: "Edit", input: ["file_path": "/r/a.swift"])))
        #expect(odd.terminalOnly)
        #expect(odd.options.isEmpty)
        #expect(!odd.permits(.accept))
    }

    @Test("Accept on a file change maps to allow")
    func acceptOnAFileChangeMapsToAllow() throws {
        let hook = try event(tool: "Write", input: ["file_path": "/r/a", "content": "x"])
        let request = try #require(ClaudePermissionAnswerBridge.request(for: hook))
        #expect(request.permits(.accept))
        #expect(
            ClaudePermissionAnswerBridge.answer(for: .accept, eventID: hook.id)
                == AgentPermissionAnswer(eventID: hook.id, verdict: .allow))
        #expect(!request.permits(.acceptForSession))
    }

    @Test("Cancel on a file change maps to deny and stop")
    func cancelMapsToDenyAndStop() throws {
        let hook = try event(tool: "Write", input: ["file_path": "/r/a", "content": "x"])
        let request = try #require(ClaudePermissionAnswerBridge.request(for: hook))
        #expect(request.permits(.cancel))
        #expect(
            ClaudePermissionAnswerBridge.answer(for: .cancel, eventID: hook.id)
                == AgentPermissionAnswer(eventID: hook.id, verdict: .deny, interrupt: true))
    }

    @Test("A command or path that was cut or changed needs the terminal")
    func incomplete() throws {
        let long = String(repeating: "x", count: CanvasAgentRequest.Limits.commandBytes + 1)
        let command = try #require(
            ClaudePermissionAnswerBridge.request(
                for: try event(tool: "Bash", input: ["command": long])))
        #expect(command.terminalOnly)
        #expect(command.options.isEmpty)
        let path = try #require(
            ClaudePermissionAnswerBridge.request(
                for: try event(tool: "Write", input: ["file_path": "/tmp/a\u{7}b"])))
        #expect(path.terminalOnly)
        #expect(path.options.isEmpty)
    }

    @Test("A Bash request that leaves the sandbox needs the terminal")
    func unsandboxed() throws {
        let request = try #require(
            ClaudePermissionAnswerBridge.request(
                for: try event(
                    tool: "Bash", input: ["command": "ls", "dangerouslyDisableSandbox": true])))
        #expect(request.command == "ls")
        #expect(request.terminalOnly)
        #expect(request.options.isEmpty)
    }

    @Test("Only a Claude PermissionRequest with a summary is answerable")
    func notAnswerable() throws {
        let plain = try event(tool: "Bash", input: ["command": "ls"], includesSummary: false)
        #expect(ClaudePermissionAnswerBridge.request(for: plain) == nil)
        let other = try event(tool: "Bash", input: ["command": "ls"], name: "PreToolUse")
        #expect(ClaudePermissionAnswerBridge.request(for: other) == nil)
        let codex = try event(tool: "Bash", input: ["command": "ls"], provider: .codex)
        #expect(ClaudePermissionAnswerBridge.request(for: codex) == nil)
        let fetch = try event(tool: "WebFetch", input: ["url": "https://example.com"])
        #expect(ClaudePermissionAnswerBridge.request(for: fetch) == nil)
    }

    @Test("Decisions map to hook answers; session grants and answers do not")
    func decisions() {
        let id = UUID()
        func answer(_ decision: CanvasAgentRequestDecision) -> AgentPermissionAnswer? {
            ClaudePermissionAnswerBridge.answer(for: decision, eventID: id)
        }
        #expect(answer(.accept) == AgentPermissionAnswer(eventID: id, verdict: .allow))
        #expect(answer(.decline) == AgentPermissionAnswer(eventID: id, verdict: .deny))
        #expect(
            answer(.cancel) == AgentPermissionAnswer(eventID: id, verdict: .deny, interrupt: true))
        #expect(answer(.acceptForSession) == nil)
        #expect(answer(.answers(["q": "yes"])) == nil)
    }

    @Test("A chosen answer is written to the waiting helper once")
    func submit() throws {
        let (bridge, root) = try temporaryBridge()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let answer = CanvasAgentRequestAnswer(key: id, decision: .accept)
        #expect(bridge.submit(answer) == .written)
        #expect(bridge.submit(answer) == .alreadyAnswered)
        #expect(
            bridge.channel.take(eventID: id) == AgentPermissionAnswer(eventID: id, verdict: .allow))
        #expect(
            bridge.submit(CanvasAgentRequestAnswer(key: UUID(), decision: .acceptForSession))
                == .unsupported)
    }

    @Test("Dismiss tells the helper to leave Claude's dialog alone")
    func dismiss() throws {
        let (bridge, root) = try temporaryBridge()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        #expect(bridge.dismiss(eventID: id) == .written)
        let outcome = bridge.channel.wait(eventID: id, timeout: 1, isWatched: { true })
        #expect(outcome == .dismissed)
        #expect(outcome.output == nil)
    }

    @MainActor
    @Test("A request in the store, once chosen, gives the helper's decision JSON")
    func throughTheStore() throws {
        let (bridge, root) = try temporaryBridge()
        defer { try? FileManager.default.removeItem(at: root) }
        let hook = try event(tool: "Bash", input: ["command": "make"])
        let request = try #require(ClaudePermissionAnswerBridge.request(for: hook))
        let store = AgentRequestStore()
        let terminal = UUID()
        #expect(store.open(request, controllerID: terminal) == .opened)
        #expect(
            store.choose(controllerID: terminal, key: hook.id, decision: .acceptForSession)
                == .invalid)
        #expect(store.choose(controllerID: terminal, key: hook.id, decision: .cancel) == .chosen)
        let chosen = try #require(store.pendingDecision(for: terminal))
        #expect(bridge.submit(chosen) == .written)
        let outcome = bridge.channel.wait(eventID: hook.id, timeout: 1, isWatched: { true })
        let json = try #require(outcome.output)
        let text = String(decoding: json, as: UTF8.self)
        #expect(text.contains(#""behavior":"deny""#))
        #expect(text.contains(#""interrupt":true"#))
    }
}
