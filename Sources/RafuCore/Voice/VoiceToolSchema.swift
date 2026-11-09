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
    public static let viewNames = [
        "view_focus", "view_zoom", "view_find", "view_tidy", "show_view", "compose_view",
    ]
    /// Ensemble tools the voice backend does not see under their MCP names.
    /// Voice gets `show_view` instead: one tool for render and update, with a
    /// flat spec so its arguments can stream into a spec decoder.
    public static let hiddenEnsembleTools: Set<String> = [
        CanvasAgentTool.viewRender.rawValue, CanvasAgentTool.viewUpdate.rawValue,
    ]
    public static let showViewName = "show_view"
    public static let composeViewName = "compose_view"
    public static let workOrderNames = ["work_order_create", "work_order_status"]
    /// The four VPLAN meta tools plus `voice_latch` ("Rafu, stay with me").
    public static let metaNames = [
        "voice_confirm", "voice_cancel", "voice_undo", "plan_preview", "voice_latch",
    ]

    /// Tools that are declared, so the model can say why, but answer
    /// `needs_phase_2` in Phase 1.
    public static let phaseTwoNames: Set<String> = [
        "handoff_to_agent", "take_back", "view_focus", "view_find", "plan_preview",
        "work_order_create", "work_order_status",
    ]

    /// Meta tools that answer a waiting Confirm card. They run at once, beside
    /// the call that waits, never queued behind it.
    public static let confirmNames: Set<String> = ["voice_confirm", "voice_cancel"]

    /// Voice texts for Ensemble tools whose MCP text speaks to an agent that
    /// has its own node. Voice has no node on the board (ADR 0035), so these
    /// never say "your node". The MCP texts stay as they are.
    public static let voiceDescriptions: [String: String] = [
        CanvasAgentTool.terminalCreate.rawValue:
            "Add a terminal node. With agent (claude, codex, opencode, gemini, cursor, kimi, cline) or command (an argument array, never a shell string) Rafu starts the shell in the visible node and types that command. prompt gives claude or codex its first task, typed as one line. Rafu places the node beside the selected or focused node; near names another node. There is no link option by voice. The reply has state: running means the shell is up and Rafu is typing the line; stopped means the node exists and the line is queued, not typed. Starting asks the user unless Agent control is Allow.",
        CanvasAgentTool.terminalSend.rawValue:
            "Types text into any terminal for the user: text into an agent terminal (claude, codex), or command (an argument array) into a shell terminal. Rafu presses Return after the line. The reply has state: stopped means the line is queued, not typed. Typing asks the user unless Agent control is Allow.",
        CanvasAgentTool.agentConfigure.rawValue:
            "Changes the model, effort or mode of a Claude Code or Codex agent running in a terminal, also mid-conversation. Claude Code changes model and effort in place (Rafu types /model and /effort). A mode change, and every Codex change, uses strategy resume: the agent quits and resumes the same conversation; that always shows a Confirm card. If the reply is error agent_busy, tell the user the agent is busy and offer to queue; if the user agrees, call again with queue true. The reply has strategy (in_place, resume or queued) and confirmed: say which way it ran and whether the terminal confirmed it. Never retry by yourself. Asks the user unless Agent control is Allow.",
        CanvasAgentTool.edgeCreate.rawValue:
            "Links two board nodes. You have no node; never use yourself as from or to. kind message links two terminals for agent messages and starts Paused; call link_set_state live to deliver messages. kind relationship is visual only.",
    ]

    /// Properties voice never offers on a tool that places a new node. `link`
    /// adds an edge from the caller's node, which voice does not have. `x` and
    /// `y` place the node; voice places it beside the selection or focus, or
    /// `near` a node. `node_update` keeps `x` and `y`: there they move a node.
    public static let voiceDroppedProperties: Set<String> = ["link", "x", "y"]

    /// The Ensemble tools, one per `CanvasAgentTool`, from MCP `definitions`
    /// (`name`, `description`, `inputSchema`). `ensemble_describe` gains an
    /// optional `ensemble` (a title or id) so Rafu can read another open board
    /// without a hand-off. Other tools lose `voiceDroppedProperties`, and
    /// `voiceDescriptions` replaces three texts.
    public static func ensembleTools(from definitions: [[String: Any]]) -> [VoiceFunctionTool] {
        definitions.compactMap { definition in
            guard let name = definition["name"] as? String,
                let description = definition["description"] as? String,
                let schema = definition["inputSchema"],
                !hiddenEnsembleTools.contains(name)
            else { return nil }
            var parameters = VoiceJSON(any: schema)
            if case .object(var object) = parameters,
                case .object(var properties) = object["properties"] ?? .object([:])
            {
                let before = properties
                if name == CanvasAgentTool.ensembleDescribe.rawValue {
                    properties["ensemble"] = property(
                        "string",
                        "Optional. The title or id of another open Ensemble. Omit for the visible one."
                    )
                }
                if name != CanvasAgentTool.nodeUpdate.rawValue {
                    for key in voiceDroppedProperties { properties[key] = nil }
                }
                if properties != before {
                    object["properties"] = .object(properties)
                    parameters = .object(object)
                }
            }
            return VoiceFunctionTool(
                name: name, description: voiceDescriptions[name] ?? description,
                parameters: parameters)
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
            showViewTool,
            composeViewTool,
        ]
    }

    /// Shows or changes a generated view. The spec keys (`root`, `elements`,
    /// `state`) sit at the top level beside `title`, `node` and `reset`, so the
    /// arguments text can stream into a spec decoder while the model speaks.
    /// Not strict-mode: `elements` is a map with free-form `props`.
    public static var showViewTool: VoiceFunctionTool {
        VoiceFunctionTool(
            name: showViewName,
            description:
                "Show the user a small native view on the visible Ensemble (a table, chart, stat, "
                + "checklist, file list…). Put the data in state and bind it. Write title first, "
                + "then root, then elements, then state. Give node to replace an existing view's "
                + "spec instead. To restore a view's initial state give node and reset true, with "
                + "root \"\" and elements {}. Put root, elements and state at the top level, not "
                + "under a spec key. In Ask mode the view appears at once with an Undo notice. "
                + "When it succeeds, say \"Showing\" and the title in a few words. "
                + CanvasAgentViewVocabulary.text,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": property("string", "Card title, at most 120 characters."),
                    "node": property(
                        "string", "Optional. A view node id or title to update; omit to create."),
                    "reset": property(
                        "boolean",
                        "Optional. Restore that view's initial state; nothing else changes."),
                    "root": property("string", "The id of the root element."),
                    "elements": VoiceJSON(any: CanvasAgentViewVocabulary.elementsSchema),
                    "state": property("object", "Optional initial state object."),
                ]),
                "required": .array(["title", "root", "elements"]),
                "additionalProperties": .bool(false),
            ]))
    }

    /// Asks Rafu to compose a view from the board data it already has. Rafu
    /// picks and arranges its own parts; the backend writes no spec. Only the
    /// backend starts it: Rafu never runs it after a `show_view` failure.
    public static var composeViewTool: VoiceFunctionTool {
        tool(
            composeViewName,
            "Ask Rafu to compose a native view for the visible Ensemble from the data it already has "
                + "(card counts, terminals, agents, files, and test output when shared). Use it when "
                + "show_view would need you to invent the layout; Rafu picks and arranges the parts. "
                + "Describe what the user wants in prompt. Never put secrets in context. In Ask mode "
                + "the view appears at once with an Undo notice. When it succeeds, say \"Showing\" "
                + "and the title in a few words.",
            [
                "prompt": property(
                    "string",
                    "What the user wants to see, in one or two sentences (at most 400 characters)."),
                "context": property(
                    "string",
                    "Optional. Extra facts the user said, at most 1,000 characters. No file contents, no terminal text."
                ),
                "title": property("string", "Optional card title, at most 120 characters."),
                "near": property(
                    "string", "Optional. A node id or title to place the card beside."),
            ], required: ["prompt"])
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
                "voice_confirm",
                "The user said yes to the action waiting on a Confirm card. Call it only after the user agreed out loud.",
                [
                    "always": property(
                        "boolean",
                        "The user said to allow this kind of action for the rest of this voice session. Never applies to removals."
                    )
                ]),
            tool(
                "voice_cancel",
                "The user said no to the action waiting on a Confirm card, or asked to stop it."),
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
            "handoff_to_agent", "take_back", "show_view", "compose_view":
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
