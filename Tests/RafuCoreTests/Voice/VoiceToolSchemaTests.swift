import Foundation
import Testing

@testable import RafuCore

@Suite("Voice tool schema")
struct VoiceToolSchemaTests {
    @Test("Every CanvasAgentTool has exactly one function tool with a closed schema")
    func ensembleToolsMirrorTheCatalog() {
        let tools = VoiceToolSchema.ensembleTools(from: CanvasAgentToolCatalog.definitions)
        #expect(
            tools.map(\.name)
                == CanvasAgentTool.allCases.map(\.rawValue).filter {
                    !VoiceToolSchema.hiddenEnsembleTools.contains($0)
                })
        #expect(!tools.contains { $0.name == "view_render" || $0.name == "view_update" })
        for tool in tools {
            #expect(tool.type == "function")
            #expect(tool.parameters["type"] == "object", Comment(rawValue: tool.name))
            #expect(tool.parameters["additionalProperties"] == false, Comment(rawValue: tool.name))
        }
        let describe = tools.first { $0.name == "ensemble_describe" }
        #expect(describe?.parameters["properties"]?["ensemble"]?["type"] == "string")
    }

    @Test("The orchestrator set is the VPLAN list of seven")
    func orchestratorSet() {
        #expect(
            VoiceToolSchema.orchestratorTools.map(\.name) == [
                "list_ensembles", "ensemble_open", "ensemble_create", "handoff_to_agent",
                "take_back", "cross_board_summary", "voice_status",
            ])
        #expect(VoiceToolSchema.orchestratorNames == VoiceToolSchema.orchestratorTools.map(\.name))
    }

    @Test("Rafu scope holds every tool once; Ensemble scope drops the orchestrator")
    func scopes() {
        let rafu = VoiceToolSchema.tools(for: .rafu).map(\.name)
        #expect(Set(rafu).count == rafu.count)
        #expect(
            rafu.count
                == CanvasAgentTool.allCases.count - VoiceToolSchema.hiddenEnsembleTools.count
                + 7 + VoiceToolSchema.viewNames.count
                + VoiceToolSchema.workOrderNames.count + VoiceToolSchema.metaNames.count)
        let ensemble = VoiceToolSchema.tools(for: .ensemble(boardID: "x")).map(\.name)
        #expect(!ensemble.contains("list_ensembles"))
        #expect(ensemble.contains("voice_undo"))
        for tool in VoiceToolSchema.tools(for: .rafu) {
            #expect(tool.parameters["additionalProperties"] == false, Comment(rawValue: tool.name))
        }
    }

    @Test("Phase 2 tools are declared and marked")
    func phaseTwo() {
        let names = Set(VoiceToolSchema.tools(for: .rafu).map(\.name))
        #expect(VoiceToolSchema.phaseTwoNames.isSubset(of: names))
        #expect(!VoiceToolSchema.phaseTwoNames.contains("voice_undo"))
        #expect(VoiceToolSchema.confirmNames.isSubset(of: names))
        #expect(VoiceToolSchema.confirmNames.isDisjoint(with: VoiceToolSchema.phaseTwoNames))
        #expect(VoiceToolSchema.extraRisk(of: "work_order_create") == .sensitive)
        #expect(VoiceToolSchema.extraRisk(of: "list_ensembles") == .read)
        #expect(VoiceToolSchema.extraRisk(of: "view_tidy") == .edit)
        #expect(VoiceToolSchema.extraRisk(of: "show_view") == .edit)
    }

    @Test("show_view replaces the two MCP view tools with a flat spec")
    func showView() {
        let names = VoiceToolSchema.tools(for: .rafu).map(\.name)
        #expect(names.contains(VoiceToolSchema.showViewName))
        #expect(VoiceToolSchema.hiddenEnsembleTools.isDisjoint(with: names))
        let tool = VoiceToolSchema.showViewTool
        #expect(tool.parameters["additionalProperties"] == false)
        #expect(tool.parameters["properties"]?["elements"]?["type"] == "object")
        #expect(tool.parameters["properties"]?["root"]?["type"] == "string")
        #expect(tool.parameters["required"] == ["title", "root", "elements"])
    }

    @Test("show_view appears once in both scopes; the MCP view tools never")
    func showViewInBothScopes() {
        for scope in [VoiceToolScope.rafu, .ensemble(boardID: "x")] {
            let names = VoiceToolSchema.tools(for: scope).map(\.name)
            #expect(names.filter { $0 == "show_view" }.count == 1)
            #expect(!names.contains("view_render"))
            #expect(!names.contains("view_update"))
        }
        let tool = VoiceToolSchema.showViewTool
        #expect(tool.description.contains(CanvasAgentViewVocabulary.text))
        #expect(tool.description.contains("reset true"))
        #expect(tool.parameters["properties"]?["node"]?["type"] == "string")
        #expect(tool.parameters["properties"]?["reset"]?["type"] == "boolean")
        #expect(
            tool.parameters["properties"]?["elements"]?["additionalProperties"]?["required"]
                == ["type"])
    }

    @Test("compose_view appears once in both scopes, is an edit, and needs only prompt")
    func composeView() {
        for scope in [VoiceToolScope.rafu, .ensemble(boardID: "x")] {
            let names = VoiceToolSchema.tools(for: scope).map(\.name)
            #expect(names.filter { $0 == VoiceToolSchema.composeViewName }.count == 1)
        }
        #expect(VoiceToolSchema.viewNames.contains("compose_view"))
        #expect(VoiceToolSchema.extraRisk(of: "compose_view") == .edit)
        let tool = VoiceToolSchema.composeViewTool
        #expect(tool.name == "compose_view")
        #expect(tool.parameters["additionalProperties"] == false)
        #expect(tool.parameters["required"] == ["prompt"])
        for key in ["prompt", "context", "title", "near"] {
            #expect(
                tool.parameters["properties"]?[key]?["type"] == "string", Comment(rawValue: key))
        }
        #expect(!tool.description.contains("Canvas"))
        #expect(!tool.description.contains("Conductor"))
    }

    @Test("Literal schemas convert without turning booleans into numbers")
    func jsonConversion() {
        let value = VoiceJSON(any: ["a": true, "b": 1, "c": 1.5, "d": ["x"]] as [String: Any])
        #expect(value == ["a": true, "b": 1, "c": 1.5, "d": ["x"]])
        #expect(VoiceJSON.object(["b": 1, "a": "x"]).jsonString() == #"{"a":"x","b":1}"#)
    }

    @Test("The Rafu persona builds a start and an update with the chosen backend")
    func persona() {
        let tools = VoiceToolSchema.tools(for: .rafu)
        let start = VoiceSessionPlan.start(
            persona: VoicePersona.rafu.with(voice: .cedar), backend: .luna, tools: tools)
        #expect(start.model == "gpt-live-1")
        #expect(start.voice == .cedar)
        #expect(start.delegation.model == "gpt-6-luna")
        #expect(start.delegation.tools.count == tools.count)
        let update = VoiceSessionPlan.update(
            persona: .rafu, backend: .terra, tools: tools, context: "Style: brief.")
        #expect(update.instructions.hasSuffix("Style: brief."))
        #expect(VoiceBackendModel.default == .terra)
        #expect(VoiceVoice.default == .marin)
        #expect(VoiceVoice.allCases.count == 25)
        let rules = VoicePersona.rafu.backendInstructions()
        #expect(rules.contains("You have no node on the board. Never pass link."))
        #expect(rules.contains("Never use yourself as from or to in edge_create."))
        #expect(rules.contains("A dialog inside Claude or Codex is not a Rafu Confirm card."))
        #expect(rules.contains("Answer a terminal dialog with terminal_send."))
        #expect(rules.contains("A node's agent is the launched agent, not proof that it runs."))
        #expect(rules.contains("do not tell the user to close views"))
    }

    @Test("Voice terminal_create has no link, x or y; node_update keeps x and y")
    func voiceDropsLinkAndPosition() {
        let tools = VoiceToolSchema.ensembleTools(from: CanvasAgentToolCatalog.definitions)
        func properties(_ name: String) -> VoiceJSON? {
            tools.first { $0.name == name }?.parameters["properties"]
        }
        for name in ["terminal_create", "note_create", "node_create", "diagram_build"] {
            let props = properties(name)
            #expect(props != nil, Comment(rawValue: name))
            #expect(props?["link"] == nil, Comment(rawValue: name))
            #expect(props?["x"] == nil, Comment(rawValue: name))
            #expect(props?["y"] == nil, Comment(rawValue: name))
            #expect(props?["near"] != nil, Comment(rawValue: name))
        }
        #expect(properties("node_update")?["x"] != nil)
        #expect(properties("node_update")?["y"] != nil)
        // The MCP catalog itself keeps link, x and y for agents.
        let mcp = CanvasAgentToolCatalog.definitions.first {
            $0["name"] as? String == "terminal_create"
        }
        let mcpProperties = (mcp?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
        #expect(mcpProperties?["link"] != nil)
        #expect(mcpProperties?["x"] != nil)
    }

    @Test("Voice descriptions never say \"your node\" and name the voice rules")
    func voiceDescriptions() {
        let tools = VoiceToolSchema.ensembleTools(from: CanvasAgentToolCatalog.definitions)
        for tool in tools {
            #expect(
                !tool.description.lowercased().contains("your node"), Comment(rawValue: tool.name))
            #expect(
                !tool.parameters.jsonString().lowercased().contains("your node"),
                Comment(rawValue: tool.name))
        }
        let create = tools.first { $0.name == "terminal_create" }?.description ?? ""
        #expect(create.contains("There is no link option by voice"))
        #expect(create.contains("beside the selected or focused node"))
        let send = tools.first { $0.name == "terminal_send" }?.description ?? ""
        #expect(send.contains("into any terminal for the user"))
        #expect(!send.contains("you created"))
        let edge = tools.first { $0.name == "edge_create" }?.description ?? ""
        #expect(edge.contains("never use yourself as from or to"))
        for name in VoiceToolSchema.voiceDescriptions.keys {
            #expect(tools.contains { $0.name == name }, Comment(rawValue: name))
        }
    }
}
