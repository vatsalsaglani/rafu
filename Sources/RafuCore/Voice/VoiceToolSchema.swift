import Foundation

/// One Responses function tool, as `delegation.responses.tools[]` takes it.
public nonisolated struct VoiceFunctionTool: Codable, Hashable, Sendable {
    public var type: String
    public var name: String
    public var description: String
    public var parameters: VoiceJSON

    public init(name: String, description: String, parameters: VoiceJSON) {
        self.type = "function"
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// Which tools the backend sees. Phase 1 runs only `.rafu`: the orchestrator
/// tools plus the Ensemble set on the visible board. Phase 2 hands off to an
/// `.ensemble` persona with `session.update`.
public nonisolated enum VoiceToolScope: Hashable, Sendable {
    case rafu
    case ensemble(boardID: String)
}

/// The voice tool surface. The Ensemble tools come from the MCP catalog, so
/// voice and agents can never drift apart; the rest is written here.
public nonisolated enum VoiceToolSchema {
    /// The seven orchestrator tools (VPLAN "Tool sets per layer").
    public static let orchestratorNames = [
        "list_ensembles", "ensemble_open", "ensemble_create", "handoff_to_agent", "take_back",
        "cross_board_summary", "voice_status",
    ]
    public static let viewNames = ["view_focus", "view_zoom", "view_find", "view_tidy"]
    public static let workOrderNames = ["work_order_create", "work_order_status"]
    /// The four VPLAN meta tools plus `voice_latch` ("Rafu, stay with me").
    public static let metaNames = [
        "voice_confirm", "voice_cancel", "voice_undo", "plan_preview", "voice_latch",
    ]

    /// Tools that are declared, so the model can say why, but answer
    /// `needs_phase_2` in Phase 1.
    public static let phaseTwoNames: Set<String> = [
        "handoff_to_agent", "take_back", "view_focus", "view_find", "plan_preview",
        "work_order_create", "work_order_status", "voice_confirm", "voice_cancel",
    ]

    /// The Ensemble tools, one per `CanvasAgentTool`, from MCP `definitions`
    /// (`name`, `description`, `inputSchema`). `ensemble_describe` gains an
    /// optional `ensemble` (a title or id) so Rafu can read another open board
    /// without a hand-off.
    public static func ensembleTools(from definitions: [[String: Any]]) -> [VoiceFunctionTool] {
        definitions.compactMap { definition in
            guard let name = definition["name"] as? String,
                let description = definition["description"] as? String,
                let schema = definition["inputSchema"]
            else { return nil }
            var parameters = VoiceJSON(any: schema)
            if name == CanvasAgentTool.ensembleDescribe.rawValue,
                case .object(var object) = parameters,
                case .object(var properties) = object["properties"] ?? .object([:])
            {
                properties["ensemble"] = property(
                    "string",
                    "Optional. The title or id of another open Ensemble. Omit for the visible one.")
                object["properties"] = .object(properties)
                parameters = .object(object)
            }
            return VoiceFunctionTool(name: name, description: description, parameters: parameters)
        }
    }

    public static var orchestratorTools: [VoiceFunctionTool] {
        [
            tool(
                "list_ensembles",
                "List the Ensembles open in Rafu's windows, plus the saved Ensembles of the front workspace. Read-only."
            ),
            tool(
                "ensemble_open",
                "Bring an Ensemble forward in its window, or open a saved Ensemble of the front workspace.",
                ["ensemble": property("string", "The Ensemble title or id from list_ensembles.")],
                required: ["ensemble"]),
            tool(
                "ensemble_create",
                "Create a new Ensemble in the front workspace window and show it.",
                [
                    "title": property("string", "Title, at most 120 characters."),
                    "alias": property(
                        "string", "Optional spoken alias. Saved from Phase 2; ignored now."),
                ], required: ["title"]),
            tool(
                "handoff_to_agent",
                "Hand the conversation to an Ensemble's own persona. Not available yet.",
                ["ensemble": property("string", "The Ensemble title or alias.")],
                required: ["ensemble"]),
            tool("take_back", "Return the conversation to Rafu. Not available yet."),
            tool(
                "cross_board_summary",
                "A short digest of every open Ensemble: node counts, running terminals, Agent control. Read-only."
            ),
            tool(
                "voice_status",
                "This voice session: persona, backend model, voice, minutes and cost this month, and the visible Ensemble. Read-only."
            ),
        ]
    }

    public static var viewTools: [VoiceFunctionTool] {
        [
            tool(
                "view_focus", "Zoom to one node. Not available yet.",
                ["node_id": property("string", "A node id, title, or \"selected\".")],
                required: ["node_id"]),
            tool(
                "view_zoom",
                "Change the visible Ensemble's zoom. fit shows every node; selection zooms to the selected nodes; in and out step.",
                [
                    "mode": property(
                        "string", "How to zoom.",
                        ["enum": .array(["fit", "selection", "in", "out"].map { .string($0) })])
                ], required: ["mode"]),
            tool(
                "view_find", "Find nodes by text. Not available yet.",
                ["query": property("string", "Words to find.")], required: ["query"]),
            tool(
                "view_tidy",
                "Tidy Up: group related nodes into clusters and fit the view. One undo step."),
        ]
    }

    public static var workOrderTools: [VoiceFunctionTool] {
        [
            tool(
                "work_order_create",
                "Ask a Claude or Codex terminal to do code work. Not available yet.",
                [
                    "agent": property("string", "claude or codex."),
                    "prompt": property("string", "The task."),
                    "target": property("string", "Optional terminal node id or title."),
                ], required: ["agent", "prompt"]),
            tool(
                "work_order_status", "How a work order is going. Not available yet.",
                ["work_order": property("string", "The work order id.")]),
        ]
    }

    public static var metaTools: [VoiceFunctionTool] {
        [
            tool(
                "voice_confirm", "Confirm the waiting action. Not available yet.",
                ["always": property("boolean", "Remember the answer for this tool.")]),
            tool("voice_cancel", "Cancel the waiting action. Not available yet."),
            tool(
                "voice_undo",
                "Undo the newest change made by voice on the visible Ensemble, when nothing changed after it."
            ),
            tool(
                "plan_preview", "Show a plan before acting. Not available yet.",
                ["summary": property("string", "One line per step.")]),
            tool(
                "voice_latch",
                "Keep the microphone open without the key (\"stay with me\"). The user sees it and Rafu checks in after 45 seconds of silence."
            ),
        ]
    }

    public static func tools(
        for scope: VoiceToolScope,
        definitions: [[String: Any]] = CanvasAgentToolCatalog.definitions
    ) -> [VoiceFunctionTool] {
        let ensemble = ensembleTools(from: definitions) + viewTools + workOrderTools + metaTools
        switch scope {
        case .rafu: return orchestratorTools + ensemble
        case .ensemble: return ensemble
        }
    }

    /// The risk of a tool that is not a `CanvasAgentTool`, under the same
    /// Off / Ask / Allow rules. `nil` for a meta tool, which never changes
    /// the board by itself.
    public static func extraRisk(of name: String) -> CanvasAgentRisk? {
        switch name {
        case "list_ensembles", "cross_board_summary", "voice_status", "work_order_status",
            "view_find":
            return .read
        case "ensemble_open", "ensemble_create", "view_focus", "view_zoom", "view_tidy",
            "handoff_to_agent", "take_back":
            return .edit
        case "work_order_create": return .sensitive
        default: return nil
        }
    }

    // MARK: Builders

    static func property(
        _ type: String, _ description: String, _ extra: [String: VoiceJSON] = [:]
    ) -> VoiceJSON {
        var value: [String: VoiceJSON] = [
            "type": .string(type), "description": .string(description),
        ]
        for (key, item) in extra { value[key] = item }
        return .object(value)
    }

    static func tool(
        _ name: String, _ description: String, _ properties: [String: VoiceJSON] = [:],
        required: [String] = []
    ) -> VoiceFunctionTool {
        VoiceFunctionTool(
            name: name, description: description,
            parameters: .object([
                "type": .string("object"), "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
                "additionalProperties": .bool(false),
            ]))
    }
}
