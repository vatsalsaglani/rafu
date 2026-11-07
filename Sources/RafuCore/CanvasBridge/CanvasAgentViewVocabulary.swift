import Foundation

/// The generated-view vocabulary for the `view_render` / `view_update` MCP
/// tools and the voice `show_view` tool (wave 3).
///
/// RafuCore has no package dependency (the `rafu` MCP server links it), so the
/// spec schema is hand-written here and the component text is a generated
/// constant. jr-4c owns this file after the contract commit: it fills `text`
/// from `RafuCatalog.rafu.prompt(…)` and adds a drift test in RafuAppTests.
public nonisolated enum CanvasAgentViewVocabulary {
    /// The `spec` parameter as a JSON Schema. Not strict-mode: `elements` is a
    /// map and `props` is free-form, which a strict schema cannot express.
    public static var specSchema: [String: Any] {
        let idList: [String: Any] = ["type": "array", "items": ["type": "string"]]
        let element: [String: Any] = [
            "type": "object",
            "properties": [
                "type": [
                    "type": "string", "description": "A component name from the vocabulary.",
                ],
                "props": [
                    "type": "object",
                    "description":
                        "Component props; values may be {\"$state\": \"/path\"}, "
                        + "{\"$bindState\": \"/path\"}, {\"$cond\": …}, {\"$computed\": …} "
                        + "or \"${/path}\" templates.",
                ],
                "children": idList,
                "slots": ["type": "object", "additionalProperties": idList],
                "visible": ["description": "true, false, or a condition object."],
                "on": [
                    "type": "object",
                    "description": "event → action binding or array of bindings.",
                ],
                "repeat": [
                    "type": "object",
                    "properties": [
                        "statePath": [String: Any](), "key": ["type": "string"],
                    ] as [String: Any],
                ],
                "watch": ["type": "object"],
            ] as [String: Any],
            "required": ["type"],
        ]
        return [
            "type": "object",
            "description":
                "A json-render spec: root (an element id), elements (id → element), "
                + "optional state.",
            "properties": [
                "root": ["type": "string"],
                "elements": ["type": "object", "additionalProperties": element],
                "state": ["type": "object"],
            ] as [String: Any],
            "required": ["root", "elements"],
            "additionalProperties": false,
        ]
    }

    /// The `elements` property of `specSchema`, for the flat voice schema.
    public static var elementsSchema: [String: Any] {
        (specSchema["properties"] as? [String: Any])?["elements"] as? [String: Any] ?? [:]
    }

    /// The component vocabulary, generated from `RafuCatalog.rafu.prompt()` and
    /// trimmed to at most 6 KiB. Placeholder until jr-4c generates it.
    public static let text = "Components and rules: see the rafu-view skill."
}
