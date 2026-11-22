import Foundation
import Testing

@testable import RafuCore

@Suite("Agent request shape")
struct AgentRequestShapeTests {
    private static let secret = "sk-ant-api03-SECRET-value-0042"

    @Test("A shape holds names and types, never a value")
    func noValues() throws {
        let value: [String: Any] = [
            "token": Self.secret, "count": 7, "flag": true, "none": NSNull(),
            "list": [Self.secret, Self.secret],
            "_meta": [
                "codex_approval_kind": "mcp_tool_call", "tool_params": ["key": Self.secret],
                "persist": ["session", "always"],
            ] as [String: Any],
        ]
        let shape = AgentRequestShape.describe(
            name: "mcpServer/elicitation/request", value: value, keyNames: .recorded)
        #expect(!shape.contains(Self.secret))
        #expect(!shape.contains("mcp_tool_call"))
        #expect(!shape.contains("session"))
        #expect(
            shape
                == "mcpServer/elicitation/request {_meta:{codex_approval_kind:string,persist:array[2],tool_params:object},count:number,flag:bool,list:array[2],none:null,token:string}"
        )
    }

    @Test("Counted key names show only counts per type")
    func countedNames() {
        let shape = AgentRequestShape.describe(
            name: "mcp__srv__tool",
            value: ["chosen_by_server": Self.secret, "other": 1, "third": "x"],
            keyNames: .counted)
        #expect(shape == "mcp__srv__tool object[3]{number:1,string:2}")
        #expect(!shape.contains("chosen_by_server"))
        #expect(!shape.contains(Self.secret))
    }

    @Test("Schema properties show as a count; unsafe names and keys show as ?")
    func unsafeParts() {
        let shape = AgentRequestShape.describe(
            name: "a name with spaces",
            value: [
                "requestedSchema": ["type": "object", "properties": ["email": ["type": "string"]]],
                "bad key!": 1, "key\u{202E}": 2,
            ] as [String: Any],
            keyNames: .recorded)
        #expect(shape.hasPrefix("? {"))
        #expect(shape.contains("requestedSchema:{properties:object[1],type:string}"))
        #expect(!shape.contains("email"))
        #expect(!shape.contains("bad key"))
        #expect(shape.contains("?:number"))
    }

    @Test("A non-object value shows only its type; deep levels show as object")
    func levels() {
        #expect(
            AgentRequestShape.describe(name: "x", value: Self.secret, keyNames: .recorded)
                == "x string")
        #expect(AgentRequestShape.describe(name: "x", value: nil, keyNames: .recorded) == "x null")
        let deep: [String: Any] = ["a": ["b": ["c": ["d": 1]]]]
        #expect(
            AgentRequestShape.describe(name: "x", value: deep, keyNames: .recorded)
                == "x {a:{b:object}}")
    }

    @Test("A shape is bounded and a spooled one is sanitized again")
    func bounds() {
        var wide: [String: Any] = [:]
        for index in 0..<200 { wide["key_number_\(index)"] = index }
        let shape = AgentRequestShape.describe(name: "x", value: wide, keyNames: .recorded)
        #expect(shape.utf8.count <= AgentRequestShape.maximumBytes)
        #expect(shape.hasSuffix("…"))
        #expect(
            AgentRequestShape.sanitized("ok {a:string}\n\u{202E}\"value\"") == "ok {a:string}value")
        #expect(AgentRequestShape.sanitized("\n\u{7}") == nil)
    }

    @Test("The recorder logs each distinct shape once, up to its limit")
    func recorder() {
        let recorder = AgentRequestShape.Recorder(subsystem: "rafu.tests")
        #expect(recorder.record("claude X {a:string}"))
        #expect(!recorder.record("claude X {a:string}"))
        #expect(!recorder.record("\u{7}"))
        for index in 1..<AgentRequestShape.Recorder.maximumShapes {
            #expect(recorder.record("claude X\(index) {a:string}"))
        }
        #expect(!recorder.record("claude Y {a:string}"))
    }
}
