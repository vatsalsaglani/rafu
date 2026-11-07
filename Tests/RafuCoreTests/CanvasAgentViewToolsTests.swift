import Foundation
import Testing

@testable import RafuCore

private let viewNode = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

private var tableSpec: [String: Any] {
    [
        "root": "card",
        "elements": [
            "card": ["type": "Card", "props": ["title": "Secret title"], "children": ["t", "x"]],
            "t": ["type": "Table", "props": ["rows": [["a": "https://example.com/x"]]]],
            "x": ["type": "Text", "props": ["text": "private words"]],
        ],
    ]
}

@Test func viewRenderParsesTheSpecIntoCanonicalText() throws {
    let call = try CanvasAgentToolCall.parse(
        tool: "view_render", arguments: ["spec": tableSpec, "title": "Report"])
    let spec = try #require(call.viewSpec)
    #expect(spec.hasPrefix(#"{"elements":{"card":"#))
    #expect(spec.contains("https://example.com/x"))
    #expect(call.diagram == nil)
    #expect(call.risk == .edit)
    let decoded = try JSONDecoder().decode(
        CanvasAgentToolCall.self, from: JSONEncoder().encode(call))
    #expect(decoded == call)
}

@Test func viewApprovalSummaryShowsCountsAndTypesNeverText() throws {
    let call = try CanvasAgentToolCall.parse(tool: "view_render", arguments: ["spec": tableSpec])
    let summary = call.approvalSummary.joined(separator: "\n")
    #expect(summary.contains("View: 3 elements; Card, Table, Text"))
    #expect(!summary.contains("Secret"))
    #expect(!summary.contains("private"))
    #expect(!summary.contains("example.com"))
}

@Test func viewSpecShapeAndSizeAreBounded() {
    func reason(_ spec: Any) -> String? {
        do {
            _ = try CanvasAgentToolCall.parse(tool: "view_render", arguments: ["spec": spec])
            return nil
        } catch {
            return error.message
        }
    }
    #expect(reason(["root": "r"])?.hasPrefix(#"Invalid value for "spec":"#) == true)
    #expect(reason("text")?.contains("root (string) and elements (object)") == true)
    let big: [String: Any] = [
        "root": "r",
        "elements": [
            "r": [
                "type": "Text",
                "props": ["text": String(repeating: "a", count: 50 * 1_024)],
            ]
        ],
    ]
    #expect(reason(big)?.contains("48 KiB per call") == true)
    let proto: [String: Any] = [
        "root": "r", "elements": ["r": ["type": "Text", "props": ["__proto__": [String: Any]()]]],
    ]
    #expect(reason(proto)?.contains("forbidden key") == true)
}

@Test func viewUpdateTakesExactlyOneChange() throws {
    let patch = try CanvasAgentToolCall.parse(
        tool: "view_update",
        arguments: ["node_id": viewNode, "patches": #"{"op":"add","path":"/state/a","value":1}"#])
    #expect(patch.viewPatches != nil)
    #expect(patch.approvalSummary.contains("Patches: 1 line"))
    let reset = try CanvasAgentToolCall.parse(
        tool: "view_update", arguments: ["node_id": viewNode, "reset": true])
    #expect(reset.reset == true)
    #expect(reset.approvalSummary.contains("Reset the view's state"))

    #expect(throws: CanvasAgentToolError.missingArgument("spec")) {
        try CanvasAgentToolCall.parse(tool: "view_update", arguments: ["node_id": viewNode])
    }
    #expect(
        throws: CanvasAgentToolError.invalidArgumentReason(
            key: "spec", reason: "give spec, patches or reset, not two")
    ) {
        try CanvasAgentToolCall.parse(
            tool: "view_update",
            arguments: ["node_id": viewNode, "spec": tableSpec, "reset": true])
    }
    #expect(throws: CanvasAgentToolError.missingArgument("node_id")) {
        try CanvasAgentToolCall.parse(tool: "view_update", arguments: ["reset": true])
    }
    #expect(throws: CanvasAgentToolError.unexpectedArgument("patches")) {
        try CanvasAgentToolCall.parse(
            tool: "view_render", arguments: ["spec": tableSpec, "patches": "{}"])
    }
    #expect(throws: (any Error).self) {
        try CanvasAgentToolCall.parse(
            tool: "view_update", arguments: ["node_id": viewNode, "patches": "op add"])
    }
}

@Test func diagramBuildStillParsesItsOwnSpec() throws {
    let call = try CanvasAgentToolCall.parse(
        tool: "diagram_build",
        arguments: ["spec": ["nodes": [["id": "a", "kind": "note", "label": "A"]]]])
    #expect(call.diagram != nil)
    #expect(call.viewSpec == nil)
}

@Test func viewToolDefinitionsCarryTheSpecSchema() throws {
    let definitions = CanvasAgentToolCatalog.definitions
    for name in ["view_render", "view_update"] {
        let definition = try #require(definitions.first { $0["name"] as? String == name })
        let schema = try #require(definition["inputSchema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let spec = try #require(properties["spec"] as? [String: Any])
        #expect(spec["required"] as? [String] == ["root", "elements"])
    }
}
