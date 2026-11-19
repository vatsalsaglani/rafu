import Foundation
import Testing

@testable import RafuCore

private let commandMethod = "item/commandExecution/requestApproval"
private let fileChangeMethod = "item/fileChange/requestApproval"
private let permissionsMethod = "item/permissions/requestApproval"
private let userInputMethod = "item/tool/requestUserInput"

private func question(
    _ id: String, labels: [String] = ["Yes", "No"], isOther: Bool = false,
    isSecret: Bool = false
) -> [String: Any] {
    [
        "id": id, "header": "Header", "question": "Pick one for \(id)?",
        "isOther": isOther, "isSecret": isSecret,
        "options": labels.map { ["label": $0, "description": "About \($0)"] },
    ]
}

private func userInput(_ questions: [[String: Any]]) throws -> CanvasAgentRequest {
    try #require(
        CanvasAgentRequest.parse(
            method: userInputMethod,
            params: ["threadId": "t", "isBlocking": true, "questions": questions]))
}

private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
    try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
}

@Suite("Agent request contract")
struct CanvasAgentRequestTests {
    // MARK: Kinds and options

    @Test("A command request keeps its text and offers four verdicts")
    func commandRequest() throws {
        let request = try #require(
            CanvasAgentRequest.parse(
                method: commandMethod,
                params: [
                    "threadId": "t", "command": "python3 fix.py\n\tdone", "cwd": "/repo",
                    "reason": "Run the fixer", "kind": "command",
                ]))
        #expect(request.kind == .command)
        #expect(request.command == "python3 fix.py\n\tdone")
        #expect(request.cwd == "/repo")
        #expect(request.reason == "Run the fixer")
        #expect(!request.terminalOnly)
        #expect(!request.isHumanCheckpoint)
        #expect(request.options.map(\.id) == ["accept", "acceptForSession", "decline", "cancel"])
        for decision in [
            CanvasAgentRequestDecision.accept, .acceptForSession, .decline, .cancel,
        ] {
            #expect(request.permits(decision))
            #expect(request.result(for: decision)?["decision"] as? String == decision.name)
        }
        #expect(!request.permits(.answers([:])))
    }

    @Test("A human checkpoint allows only accept, decline and cancel")
    func humanCheckpoint() throws {
        let request = try #require(
            CanvasAgentRequest.parse(
                method: commandMethod, params: ["command": "deploy", "kind": "humanCommand"]))
        #expect(request.isHumanCheckpoint)
        #expect(request.options.map(\.decision) == [.accept, .decline, .cancel])
        #expect(!request.permits(.acceptForSession))
        #expect(request.result(for: .acceptForSession) == nil)
    }

    @Test("An unknown command kind or a missing command needs the terminal")
    func unknownCommandKind() throws {
        let unknown = try #require(
            CanvasAgentRequest.parse(
                method: commandMethod, params: ["command": "ls", "kind": "futureKind"]))
        #expect(unknown.terminalOnly)
        #expect(unknown.options.isEmpty)
        #expect(!unknown.permits(.accept))
        let missing = try #require(
            CanvasAgentRequest.parse(method: commandMethod, params: ["reason": "why"]))
        #expect(missing.terminalOnly)
    }

    @Test("A file change offers four verdicts and keeps its grant root")
    func fileChange() throws {
        let request = try #require(
            CanvasAgentRequest.parse(
                method: fileChangeMethod,
                params: ["reason": "Edit two files", "grantRoot": "/repo/src", "command": "x"]))
        #expect(request.kind == .fileChange)
        #expect(request.grantRoot == "/repo/src")
        #expect(request.command == nil)
        #expect(request.options.count == 4)
        #expect(request.permits(.cancel))
    }

    @Test("A permissions request lists its grants and echoes the asked profile")
    func permissions() throws {
        let profile: [String: Any] = [
            "network": ["enabled": true],
            "fileSystem": [
                "write": ["/repo/out"],
                "entries": [["access": "read", "path": ["type": "path", "path": "/etc/hosts"]]],
            ],
        ]
        let request = try #require(
            CanvasAgentRequest.parse(
                method: permissionsMethod,
                params: ["cwd": "/repo", "reason": "Need net", "permissions": profile]))
        #expect(request.kind == .permissions)
        #expect(request.permissions == ["Network access", "Write /repo/out", "Read /etc/hosts"])
        #expect(!request.terminalOnly)
        #expect(request.options.map(\.decision) == [.accept, .acceptForSession, .decline])
        #expect(!request.permits(.cancel))
        let accept = try #require(request.result(for: .accept, requestedPermissions: profile))
        #expect(accept["scope"] as? String == "turn")
        #expect(
            (accept["permissions"] as? [String: Any])?.keys.sorted() == ["fileSystem", "network"])
        let session = try #require(
            request.result(for: .acceptForSession, requestedPermissions: profile))
        #expect(session["scope"] as? String == "session")
        let decline = try #require(request.result(for: .decline))
        #expect((decline["permissions"] as? [String: Any])?.isEmpty == true)
        // Accepting needs the exact profile that was asked for.
        #expect(request.result(for: .accept) == nil)
    }

    @Test("A permissions profile Rafu cannot read needs the terminal")
    func unknownPermissions() throws {
        let request = try #require(
            CanvasAgentRequest.parse(
                method: permissionsMethod,
                params: ["permissions": ["network": ["enabled": true], "future": [:]]]))
        #expect(request.terminalOnly)
        let empty = try #require(
            CanvasAgentRequest.parse(method: permissionsMethod, params: ["permissions": [:]]))
        #expect(empty.terminalOnly)
    }

    @Test("Unknown methods are not requests")
    func unknownMethod() {
        #expect(
            CanvasAgentRequest.parse(method: "mcpServer/elicitation/request", params: [:]) == nil)
        #expect(CanvasAgentRequest.parse(method: "execCommandApproval", params: [:]) == nil)
    }

    // MARK: Sanitizer limits

    @Test("A long command is cut at a character boundary and needs the terminal")
    func longCommand() throws {
        let command = String(repeating: "é", count: 1_500)  // 3,000 bytes
        let request = try #require(
            CanvasAgentRequest.parse(method: commandMethod, params: ["command": command]))
        let kept = try #require(request.command)
        #expect(kept.utf8.count <= CanvasAgentRequest.Limits.commandBytes)
        #expect(kept.utf8.count == 2_048)
        #expect(command.hasPrefix(kept))
        #expect(request.terminalOnly)
        let exact = String(repeating: "a", count: 2_048)
        let fits = CanvasAgentRequest(kind: .command, command: exact)
        #expect(fits.command == exact)
        #expect(!fits.terminalOnly)
    }

    @Test("Control characters are stripped and an altered command needs the terminal")
    func controlCharacters() {
        let request = CanvasAgentRequest(
            kind: .command, command: "echo hi\u{1B}[2J", cwd: "/repo\n/evil\u{7}",
            reason: "Line one\nline\u{0}two\u{202E}txt.exe")
        #expect(request.command == "echo hi[2J")
        #expect(request.cwd == "/repo/evil")
        #expect(request.reason == "Line one\nlinetwotxt.exe")
        #expect(request.terminalOnly)
        let clean = CanvasAgentRequest(kind: .command, command: "make\n\ttest", reason: "ok")
        #expect(!clean.terminalOnly)
    }

    @Test("Reason and folder are bounded but stay answerable")
    func reasonAndFolderBounds() {
        let request = CanvasAgentRequest(
            kind: .command, command: "ls", cwd: String(repeating: "/d", count: 1_000),
            reason: String(repeating: "r", count: 2_000))
        #expect(request.reason?.utf8.count == CanvasAgentRequest.Limits.reasonBytes)
        #expect(request.cwd?.utf8.count == CanvasAgentRequest.Limits.cwdBytes)
        #expect(!request.terminalOnly)
    }

    // MARK: Questions

    @Test("Questions are answered with one valid label each")
    func questionAnswers() throws {
        let request = try userInput([question("a"), question("b", labels: ["Red", "Blue"])])
        #expect(request.kind == .userInput)
        #expect(!request.terminalOnly)
        #expect(request.options.isEmpty)
        #expect(request.questions.map(\.id) == ["a", "b"])
        #expect(request.questions[1].choices.map(\.label) == ["Red", "Blue"])
        #expect(request.questions[1].choices[0].detail == "About Red")
        #expect(request.permits(.answers(["a": "Yes", "b": "Blue"])))
        #expect(!request.permits(.answers(["a": "Yes"])))
        #expect(!request.permits(.answers(["a": "Yes", "b": "Green"])))
        #expect(!request.permits(.answers(["a": "Yes", "b": "Blue", "c": "No"])))
        #expect(!request.permits(.accept))
        let result = try #require(request.result(for: .answers(["a": "No", "b": "Red"])))
        let answers = try #require(result["answers"] as? [String: [String: [String]]])
        #expect(answers == ["a": ["answers": ["No"]], "b": ["answers": ["Red"]]])
    }

    @Test("Questions over the bounds keep four by six and need the terminal")
    func questionBounds() throws {
        let many = try userInput((0..<5).map { question("q\($0)") })
        #expect(many.questions.count == CanvasAgentRequest.Limits.questions)
        #expect(many.terminalOnly)
        let wide = try userInput([question("q", labels: (0..<7).map { "Option \($0)" })])
        #expect(wide.questions[0].choices.count == CanvasAgentRequest.Limits.choices)
        #expect(wide.questions[0].terminalOnly)
        #expect(wide.terminalOnly)
        #expect(!wide.permits(.answers(["q": "Option 0"])))
    }

    @Test("Secret, free-text and unclean questions need the terminal")
    func terminalOnlyQuestions() throws {
        #expect(try userInput([question("s", isSecret: true)]).terminalOnly)
        #expect(try userInput([question("o", isOther: true)]).terminalOnly)
        #expect(try userInput([question("n", labels: [])]).terminalOnly)
        #expect(try userInput([question("l", labels: ["Yes\u{1B}", "No"])]).terminalOnly)
        #expect(try userInput([question("d"), question("d")]).terminalOnly)
        #expect(try userInput([]).terminalOnly)
        #expect(try userInput([["id": "x"]]).terminalOnly)
        // One terminal-only question makes the whole request terminal-only:
        // the answer must cover every question.
        let mixed = try userInput([question("a"), question("b", isSecret: true)])
        #expect(mixed.terminalOnly)
        #expect(!mixed.questions[0].terminalOnly)
    }

    // MARK: Codable

    @Test("Requests, decisions and answers survive a JSON round trip")
    func codableRoundTrip() throws {
        let date = Date(timeIntervalSinceReferenceDate: 812_345_678.25)
        let requests = [
            CanvasAgentRequest(
                kind: .command, isHumanCheckpoint: true, command: "ls\n", cwd: "/r",
                reason: "why", receivedAt: date),
            CanvasAgentRequest(kind: .fileChange, reason: "x", grantRoot: "/g", receivedAt: date),
            CanvasAgentRequest(
                kind: .permissions, permissions: ["Network access"], receivedAt: date),
            try userInput([question("a"), question("b", isSecret: true)]),
            CanvasAgentRequest(
                kind: .command, command: String(repeating: "x", count: 3_000), receivedAt: date),
        ]
        for request in requests { #expect(try roundTrip(request) == request) }
        let decisions: [CanvasAgentRequestDecision] = [
            .accept, .acceptForSession, .decline, .cancel, .answers(["a": "Yes"]),
        ]
        for decision in decisions { #expect(try roundTrip(decision) == decision) }
        let answer = CanvasAgentRequestAnswer(key: UUID(), decision: .answers(["q": "Red"]))
        #expect(try roundTrip(answer) == answer)
    }

    @Test("The wire form carries the opaque key and no JSON-RPC id")
    func wireShape() throws {
        let request = try #require(
            CanvasAgentRequest.parse(
                method: commandMethod, params: ["command": "ls", "itemId": "item-1"]))
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(object["key"] as? String == request.key.uuidString)
        #expect(object["id"] == nil)
        #expect(object["itemId"] == nil)
    }

    @Test("Decoding rejects a value the sanitizer would change")
    func decodingRejectsUncleanValues() throws {
        let valid = CanvasAgentRequest(kind: .command, command: "ls", reason: "ok")
        let base = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        func decodes(_ change: (inout [String: Any]) -> Void) throws -> Bool {
            var object = base
            change(&object)
            let data = try JSONSerialization.data(withJSONObject: object)
            return (try? JSONDecoder().decode(CanvasAgentRequest.self, from: data)) != nil
        }
        #expect(try decodes { _ in })
        #expect(try !decodes { $0["reason"] = "bad\u{1B}" })
        #expect(try !decodes { $0["reason"] = String(repeating: "r", count: 600) })
        #expect(try !decodes { $0["command"] = String(repeating: "c", count: 3_000) })
        #expect(try !decodes { $0["command"] = "rm\u{0}" })
        // A command that needs the terminal cannot arrive marked answerable.
        #expect(try !decodes { $0["command"] = "" })
        #expect(
            try !decodes {
                $0["isHumanCheckpoint"] = true
                $0["kind"] = "fileChange"
            })
        #expect(try !decodes { $0["permissions"] = ["Network access"] })
        #expect(
            try !decodes {
                $0["questions"] = [
                    ["id": "q", "header": "", "text": "?", "terminalOnly": false, "choices": []]
                ]
            })
        #expect(try !decodes { $0["kind"] = "elicitation" })
    }

    @Test("Decision decoding rejects unknown verdicts and too many answers")
    func decisionDecoding() {
        let unknown = Data(#"{"type":"acceptWithExecpolicyAmendment"}"#.utf8)
        #expect((try? JSONDecoder().decode(CanvasAgentRequestDecision.self, from: unknown)) == nil)
        let many = Data(
            #"{"type":"answers","answers":{"a":"1","b":"1","c":"1","d":"1","e":"1"}}"#.utf8)
        #expect((try? JSONDecoder().decode(CanvasAgentRequestDecision.self, from: many)) == nil)
    }

    @Test("Bridge messages carry requests and stay compatible with older peers")
    func bridgeMessages() throws {
        let legacyRequest = Data(#"{"token":"t","clientID":"c","operation":"list"}"#.utf8)
        let decoded = try JSONDecoder().decode(CanvasBridgeRequest.self, from: legacyRequest)
        #expect(decoded.approval == nil)
        #expect(decoded.approvalKey == nil)
        let legacyResponse = Data(#"{"peers":[],"messages":[]}"#.utf8)
        #expect(
            try JSONDecoder().decode(CanvasBridgeResponse.self, from: legacyResponse)
                .approvalDecision == nil)
        let approval = CanvasAgentRequest(kind: .command, command: "ls")
        let open = CanvasBridgeRequest(
            token: "t", operation: CanvasAgentRequest.openOperation, provider: "codex",
            approval: approval)
        #expect(try roundTrip(open) == open)
        let close = CanvasBridgeRequest(
            token: "t", operation: CanvasAgentRequest.closeOperation, approvalKey: approval.key)
        #expect(try roundTrip(close) == close)
        let poll = CanvasBridgeResponse(
            approvalDecision: CanvasAgentRequestAnswer(key: approval.key, decision: .decline))
        #expect(try roundTrip(poll) == poll)
        // The largest request stays well inside one IPC frame.
        let largest = try userInput(
            (0..<4).map { index in
                question(
                    String(repeating: "i", count: 128) + "\(index)",
                    labels: (0..<6).map { String(repeating: "\($0)", count: 128) })
            })
        let full = CanvasBridgeRequest(
            token: "t", operation: CanvasAgentRequest.openOperation, approval: largest)
        #expect(try JSONEncoder().encode(full).count < LauncherIPCProtocol.maxFrameBytes / 2)
    }
}
