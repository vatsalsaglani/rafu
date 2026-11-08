import Foundation

/// The generated-view vocabulary for the `view_render` / `view_update` MCP
/// tools and the voice `show_view` tool (wave 3).
///
/// RafuCore has no package dependency (the `rafu` MCP server links it), so the
/// spec schema is hand-written here and the component text is a generated
/// constant, checked against the catalog by a drift test in RafuAppTests.
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

    /// The component vocabulary, generated from `RafuCatalog.rafu.prompt()` by
    /// `CanvasAgentViewVocabularyGenerator` (RafuApp) and trimmed to at most
    /// 6 KiB. Do not edit by hand: when the Rafu catalog changes,
    /// `CanvasAgentViewVocabularyDriftTests` fails and writes the new text to
    /// `$TMPDIR/rafu-view-vocabulary.txt`; paste it here.
    public static let text = #"""
        VOCABULARY (Rafu catalog 0.22.0-alpha.1+rafu.1). Use only these component types.
        COMPONENTS (type: props):
        - Card: { title?: string, description?: string, maxWidth?: "sm" | "md" | "lg" | "full", centered?: boolean, className?: string, variant?: "outlined" | "plain" | "elevated" } [accepts children; slots: h…
        - Stack: { direction?: "horizontal" | "vertical", gap?: "none" | "sm" | "md" | "lg" | "xl", align?: "start" | "center" | "end" | "stretch", justify?: "start" | "center" | "end" | "between" | "around", …
        - Grid: { columns?: number, gap?: "sm" | "md" | "lg" | "xl", className?: string } [accepts children]
        - Separator: { orientation?: "horizontal" | "vertical" }
        - Tabs: { tabs: Array<{ label: string, value: string }>, defaultValue?: string, value?: string, variant?: "underline" | "segmented" } [accepts children] [events: change]
        - Accordion: { items: Array<{ title: string, content: string }>, type?: "single" | "multiple" }
        - Collapsible: { title: string, defaultOpen?: boolean, open?: boolean } [accepts children]
        - Pagination: { totalPages: number, page?: number } [events: change]
        - Dialog: { title: string, description?: string, openPath: string, open?: boolean } [accepts children; slots: footer]
        - Drawer: { title: string, description?: string, openPath: string, open?: boolean } [accepts children; slots: footer]
        - Tooltip: { content: string, text: string }
        - Popover: { trigger: string, content: string }
        - DropdownMenu: { label: string, items: Array<{ label: string, value: string }>, value?: string } [events: select]
        - Heading: { text: string, level?: "h1" | "h2" | "h3" | "h4" }
        - Text: { text: string, variant?: "body" | "caption" | "muted" | "lead" | "code" }
        - Badge: { text: string, variant?: "default" | "secondary" | "destructive" | "outline" | "good" | "warning" | "critical" }
        - Alert: { title: string, message?: string, type?: "info" | "success" | "warning" | "error" }
        - Skeleton: { width?: string, height?: string, rounded?: boolean, shape?: "line" | "block" | "circle" | "card" | "tableBody" }
        - Image: { src?: string, alt: string, width?: number, height?: number, fit?: "contain" | "cover" } [slots: error, loading]
        - Avatar: { src?: string, name: string, size?: "sm" | "md" | "lg" }
        - Carousel: { items: Array<{ title?: string, description?: string }> } [accepts children]
        - Table: { columns: Array<string>, rows: Array<Array<string>>, caption?: string, sortable?: boolean } [accepts children; slots: empty, loading]
        - Progress: { value: number, max?: number, label?: string }
        - Spinner: { size?: "sm" | "md" | "lg", label?: string }
        - Button: { label: string, variant?: "primary" | "secondary" | "danger" | "destructive" | "plain", disabled?: boolean, size?: "sm" | "md" | "lg", icon?: string } [events: press]
        - Link: { label: string, href: string } [events: press]
        - Input: { label: string, name: string, type?: "text" | "email" | "password" | "number", placeholder?: string, value?: string, checks?: Array<{ type: string, message: string, args?: Record<string, unkn…
        - Textarea: { label: string, name: string, placeholder?: string, rows?: number, value?: string, checks?: Array<{ type: string, message: string, args?: Record<string, unknown> }>, validateOn?: "change" …
        - Select: { label: string, name: string, options: Array<string>, placeholder?: string, value?: string, checks?: Array<{ type: string, message: string, args?: Record<string, unknown> }>, validateOn?: "c…
        - Checkbox: { label: string, name: string, checked?: boolean, checks?: Array<{ type: string, message: string, args?: Record<string, unknown> }>, validateOn?: "change" | "blur" | "submit" } [events: cha…
        - Radio: { label: string, name: string, options: Array<string>, value?: string, checks?: Array<{ type: string, message: string, args?: Record<string, unknown> }>, validateOn?: "change" | "blur" | "subm…
        - Switch: { label: string, name: string, checked?: boolean, checks?: Array<{ type: string, message: string, args?: Record<string, unknown> }>, validateOn?: "change" | "blur" | "submit" } [events: chang…
        - Slider: { label?: string, min?: number, max?: number, step?: number, value?: number } [events: change]
        - Toggle: { label: string, pressed?: boolean, variant?: "default" | "outline" } [events: change]
        - ToggleGroup: { items: Array<{ label: string, value: string }>, type?: "single" | "multiple", value?: string } [events: change]
        - ButtonGroup: { buttons: Array<{ label: string, value: string }>, selected?: string } [events: change]
        CHARTS (props: see the json-render-swift-use skill): BarChart, LineChart, AreaChart, PieChart, Gauge, Sparkline, ScatterChart, Heatmap, Histogram, ComboChart, Waterfall, Funnel, BoxPlot, Candlestick, Treemap
        ACTIONS (on.<event>: {action, params}): setState, pushState, removeState, validateForm, toggleState, incrementState
        VISIBILITY (visible on the element, never in props): true, false, {"$state": "/path"} truthy, add one of eq, neq, gt, gte, lt, lte, or "not": true; an array is AND; {"$and": […]}, {"$or": […]}.
        DYNAMIC PROPS: {"$state": "/path"} reads, {"$bindState": "/path"} binds an input, {"$item": "field"}, {"$index": true} and {"$bindItem": "field"} inside repeat, {"$cond": …, "$then": …, "$else": …}, {"$template": "Hi ${/name}"}, {"$computed": name, "args": {…}} with groupSum, countBy, topN, bucket.
        """#
}
