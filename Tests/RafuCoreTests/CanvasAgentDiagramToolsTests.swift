import Foundation
import Testing

@testable import RafuCore

private let frameNode = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

private func spec(_ edges: [[String: Any]], direction: String? = nil) -> [String: Any] {
    var value: [String: Any] = [
        "nodes": [
            ["id": "web", "label": "Web", "pack_id": "common", "icon_id": "browser"],
            ["id": "api", "label": "API", "pack_id": "common", "icon_id": "api"],
            ["id": "db", "label": "Database", "pack_id": "common", "icon_id": "database"],
            ["id": "memo", "kind": "note", "label": "Notes"],
        ],
        "edges": edges,
        "frame": "Checkout",
    ]
    if let direction { value["direction"] = direction }
    return value
}

@Test func diagramBuildParsesAndValidatesASpec() throws {
    let call = try CanvasAgentToolCall.parse(
        tool: "diagram_build",
        arguments: [
            "spec": spec([
                ["from": "web", "to": "api", "label": "HTTPS"], ["from": "api", "to": "db"],
            ])
        ])
    let diagram = try #require(call.diagram)
    #expect(diagram.nodes.count == 4)
    #expect(diagram.nodes[3].kind == "note")
    #expect(diagram.edges[0].label == "HTTPS")
    #expect(diagram.frame == "Checkout")
    #expect(call.risk == .edit)
    #expect(call.approvalSummary.contains("Diagram: 4 nodes, 2 links"))
}

@Test func diagramBuildRejectsBadSpecs() {
    #expect(throws: CanvasAgentToolError.invalidArgument("spec.edges")) {
        try CanvasAgentToolCall.parse(
            tool: "diagram_build", arguments: ["spec": spec([["from": "web", "to": "nowhere"]])])
    }
    #expect(throws: CanvasAgentToolError.invalidArgument("spec")) {
        try CanvasAgentToolCall.parse(
            tool: "diagram_build", arguments: ["spec": ["nodes": [["id": "a", "lable": "A"]]]])
    }
    #expect(throws: CanvasAgentToolError.invalidArgument("spec.nodes")) {
        try CanvasAgentToolCall.parse(
            tool: "diagram_build",
            arguments: ["spec": ["nodes": [["id": "a", "label": "A", "icon_id": "x"]]]])
    }
    #expect(throws: CanvasAgentToolError.invalidArgument("spec.nodes")) {
        try CanvasAgentToolCall.parse(
            tool: "diagram_build",
            arguments: [
                "spec": [
                    "nodes": [
                        ["id": "a", "label": "A", "pack_id": "../x", "icon_id": "y"]
                    ]
                ]
            ])
    }
    #expect(throws: CanvasAgentToolError.invalidArgument("spec")) {
        let nodes = (0..<41).map { ["id": "n\($0)", "kind": "text", "label": "N"] }
        return try CanvasAgentToolCall.parse(
            tool: "diagram_build", arguments: ["spec": ["nodes": nodes]])
    }
    #expect(throws: CanvasAgentToolError.invalidArgument("spec.direction")) {
        try CanvasAgentToolCall.parse(
            tool: "diagram_build", arguments: ["spec": spec([], direction: "left")])
    }
}

@Test func diagramLayoutPlacesNodesInLayers() throws {
    let call = try CanvasAgentToolCall.parse(
        tool: "diagram_build",
        arguments: [
            "spec": spec([
                ["from": "web", "to": "api"], ["from": "api", "to": "db"],
                ["from": "web", "to": "db"], ["from": "db", "to": "web"],
            ])
        ])
    let diagram = try #require(call.diagram)
    let layers = CanvasAgentDiagramLayout.layers(diagram)
    // The cycle db -> web is broken in node order; it never loops forever.
    #expect(layers["web"] == 0)
    #expect(layers["memo"] == 0)
    #expect(layers["api"]! < layers["db"]!)
    let rects = CanvasAgentDiagramLayout.rects(for: diagram, originX: 100, originY: 50)
    #expect(rects.count == 4)
    let web = try #require(rects["web"])
    let api = try #require(rects["api"])
    let db = try #require(rects["db"])
    #expect(api.x > web.x)
    #expect(db.x > api.x)
    // No two rects overlap.
    let all = Array(rects.values)
    for (index, a) in all.enumerated() {
        for b in all[(index + 1)...] {
            let overlaps =
                a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height
                && b.y < a.y + a.height
            #expect(!overlaps)
        }
    }
    let bounds = try #require(CanvasAgentDiagramLayout.bounds(all))
    for rect in all {
        #expect(rect.x >= bounds.x && rect.y >= bounds.y)
        #expect(rect.x + rect.width <= bounds.x + bounds.width)
        #expect(rect.y + rect.height <= bounds.y + bounds.height)
    }
}

@Test func diagramLayoutFlowsDownWhenAsked() throws {
    let call = try CanvasAgentToolCall.parse(
        tool: "diagram_build",
        arguments: ["spec": spec([["from": "web", "to": "api"]], direction: "down")])
    let rects = CanvasAgentDiagramLayout.rects(for: try #require(call.diagram))
    #expect(rects["api"]!.y > rects["web"]!.y)
    #expect(rects["api"]!.x == rects["web"]!.x)
}

@Test func exportAndFrameArgumentsAreBounded() throws {
    let gif = try CanvasAgentToolCall.parse(
        tool: "export", arguments: ["format": "gif", "seconds": 3.0, "fps": 12])
    #expect(gif.risk == .sensitive)
    let frame = try CanvasAgentToolCall.parse(
        tool: "export", arguments: ["format": "png", "target": "frame", "frame_id": frameNode])
    #expect(frame.frameID == frameNode)
    #expect(throws: CanvasAgentToolError.missingArgument("frame_id")) {
        try CanvasAgentToolCall.parse(
            tool: "export", arguments: ["format": "pdf", "target": "frame"])
    }
    #expect(throws: CanvasAgentToolError.invalidArgument("scale")) {
        try CanvasAgentToolCall.parse(tool: "export", arguments: ["format": "pdf", "scale": 2.0])
    }
    #expect(throws: CanvasAgentToolError.invalidArgument("fps")) {
        try CanvasAgentToolCall.parse(tool: "export", arguments: ["format": "gif", "fps": 120])
    }
    #expect(throws: CanvasAgentToolError.invalidArgument("format")) {
        try CanvasAgentToolCall.parse(tool: "export", arguments: ["format": "svg"])
    }
    #expect(throws: CanvasAgentToolError.missingArgument("member_ids")) {
        try CanvasAgentToolCall.parse(
            tool: "frame_create", arguments: ["title": "Group", "member_ids": [String]()])
    }
    let created = try CanvasAgentToolCall.parse(
        tool: "frame_create", arguments: ["title": "Group", "member_ids": [frameNode]])
    #expect(created.risk == .edit)
}

@Test func iconSearchAndServiceIconNodesValidate() throws {
    let search = try CanvasAgentToolCall.parse(
        tool: "icon_search", arguments: ["query": "queue", "limit": 10])
    #expect(search.risk == .read)
    #expect(throws: CanvasAgentToolError.invalidArgument("limit")) {
        try CanvasAgentToolCall.parse(tool: "icon_search", arguments: ["query": "q", "limit": 500])
    }
    let icon = try CanvasAgentToolCall.parse(
        tool: "node_create",
        arguments: [
            "kind": "service_icon", "pack_id": "aws", "icon_id": "compute/lambda",
            "label": "Resize",
        ])
    #expect(icon.label == "Resize")
    #expect(throws: CanvasAgentToolError.missingArgument("icon_id")) {
        try CanvasAgentToolCall.parse(
            tool: "node_create", arguments: ["kind": "service_icon", "pack_id": "aws"])
    }
    #expect(throws: CanvasAgentToolError.missingArgument("title")) {
        try CanvasAgentToolCall.parse(tool: "node_create", arguments: ["kind": "frame"])
    }
}
