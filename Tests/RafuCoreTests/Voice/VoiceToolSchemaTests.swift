import Foundation
import Testing

@testable import RafuCore

@Suite("Voice tool schema")
struct VoiceToolSchemaTests {
    @Test("Every CanvasAgentTool has exactly one function tool with a closed schema")
    func ensembleToolsMirrorTheCatalog() {
        let tools = VoiceToolSchema.ensembleTools(from: CanvasAgentToolCatalog.definitions)
        #expect(tools.map(\.name) == CanvasAgentTool.allCases.map(\.rawValue))
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
                == CanvasAgentTool.allCases.count + 7 + VoiceToolSchema.viewNames.count
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
    }
}
