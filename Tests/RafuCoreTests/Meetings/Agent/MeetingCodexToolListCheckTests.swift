import Foundation
import Testing

@testable import RafuCore

@Suite("Hidden meeting agent: Codex tool-list check")
struct MeetingCodexToolListCheckTests {
    private static func request() throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: Data(CodexRecordedCaptureRequest.body.utf8))
                as? [String: Any])
    }

    private static func encode(_ request: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: request)
    }

    /// The `functions` namespace of the saved request.
    private static func namespace(_ request: [String: Any]) throws -> [String: Any] {
        let input = try #require(request["input"] as? [[String: Any]])
        let item = try #require(input.first { $0["type"] as? String == "additional_tools" })
        let tools = try #require(item["tools"] as? [[String: Any]])
        return try #require(tools.first)
    }

    private static func replacingNamespace(
        _ request: [String: Any], with namespace: [String: Any]
    ) throws -> [String: Any] {
        var request = request
        var input = try #require(request["input"] as? [[String: Any]])
        let index = try #require(input.firstIndex { $0["type"] as? String == "additional_tools" })
        input[index]["tools"] = [namespace]
        request["input"] = input
        return request
    }

    @Test("The saved request of codex-cli 0.171.0 passes")
    func savedRequestPasses() {
        #expect(
            MeetingCodexToolListCheck.check(Data(CodexRecordedCaptureRequest.body.utf8))
                == .passed)
    }

    @Test("An extra top-level tool fails")
    func extraTool() throws {
        let request = try Self.request()
        var namespace = try Self.namespace(request)
        var tools = try #require(namespace["tools"] as? [[String: Any]])
        tools.append(["type": "function", "name": "exec_command", "description": "x"])
        namespace["tools"] = tools
        let changed = try Self.replacingNamespace(request, with: namespace)
        #expect(MeetingCodexToolListCheck.check(try Self.encode(changed)) == .differentTools)

        var topLevel = request
        topLevel["tools"] = [["type": "function", "name": "shell"]]
        #expect(MeetingCodexToolListCheck.check(try Self.encode(topLevel)) == .differentTools)
    }

    @Test("A missing nested tool, or an extra one, fails")
    func nestedTools() throws {
        let request = try Self.request()
        let namespace = try Self.namespace(request)
        let tools = try #require(namespace["tools"] as? [[String: Any]])
        let execIndex = try #require(tools.firstIndex { $0["name"] as? String == "exec" })
        let description = try #require(tools[execIndex]["description"] as? String)

        for changedDescription in [
            description.replacingOccurrences(
                of: "declare const tools: { clock__curr_time(", with: "declare const x: { clock("),
            description + "\ndeclare const tools: { exec_command(args: {}): Promise<unknown>; };",
        ] {
            var changedTools = tools
            changedTools[execIndex]["description"] = changedDescription
            var changedNamespace = namespace
            changedNamespace["tools"] = changedTools
            let changed = try Self.replacingNamespace(request, with: changedNamespace)
            #expect(MeetingCodexToolListCheck.check(try Self.encode(changed)) == .differentTools)
        }
    }

    @Test("A skills block fails")
    func skillsBlock() throws {
        var request = try Self.request()
        var input = try #require(request["input"] as? [[String: Any]])
        input.append([
            "type": "message", "role": "developer",
            "content": [
                ["type": "input_text", "text": "<skills_instructions>x</skills_instructions>"]
            ],
        ])
        request["input"] = input
        #expect(MeetingCodexToolListCheck.check(try Self.encode(request)) == .differentTools)
    }

    @Test("A damaged or unknown request is unreadable")
    func damaged() throws {
        #expect(MeetingCodexToolListCheck.check(Data("not json".utf8)) == .unreadable)
        #expect(MeetingCodexToolListCheck.check(Data("{}".utf8)) == .unreadable)
        let body = Data(CodexRecordedCaptureRequest.body.utf8)
        #expect(MeetingCodexToolListCheck.check(body.prefix(body.count / 2)) == .unreadable)
        var noTools = try Self.request()
        let input = try #require(noTools["input"] as? [[String: Any]])
        noTools["input"] = input.filter { $0["type"] as? String != "additional_tools" }
        #expect(MeetingCodexToolListCheck.check(try Self.encode(noTools)) == .unreadable)
        // A nested mark that is not followed by a name fails closed.
        #expect(
            MeetingCodexToolListCheck.nestedNames(in: "declare const tools: { (x)") == nil)
    }
}
