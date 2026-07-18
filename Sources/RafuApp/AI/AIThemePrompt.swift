import Foundation

/// Builds the prompt used to have an AI model design a Rafu theme JSON.
/// Used both by "Copy Prompt" (paste into any chatbot) and by direct
/// generation through the configured provider.
nonisolated enum AIThemePrompt {
    static let instruction = """
        You are a color-system designer producing a theme for Rafu, a native \
        macOS code editor. Respond with a single JSON object and nothing else — \
        no prose, no Markdown fences. The JSON must follow the schema shown in \
        the user message exactly: same keys, hex color strings ("#RRGGBB" or \
        "#RRGGBBAA"), and "appearance" set to "light" or "dark". Design rules: \
        keep text/background contrast at WCAG AA or better, keep the editor \
        background calm, reserve the accent for emphasis, make diff and git \
        colors clearly distinguishable, and keep syntax token colors harmonious \
        with the UI palette.
        """

    static func userPrompt(description: String) -> String {
        """
        Design a Rafu editor theme from this description:

        <description>
        \(description.isEmpty ? "A tasteful, modern editor theme." : description)
        </description>

        Return only a JSON object with exactly this structure (replace every \
        color value; keep all keys):

        \(schemaTemplate)
        """
    }

    static var schemaTemplate: String {
        """
        {
          "version": 1,
          "name": "Theme Name",
          "id": "dev.rafu.user-theme.theme-name",
          "appearance": "dark",
          "author": "You",
          "description": "One sentence.",
          "ui": {
            "appBackground": "#10141C", "sidebarBackground": "#10141C",
            "editorBackground": "#151A24", "elevatedBackground": "#1B212D",
            "statusBarBackground": "#10141C", "tabBarBackground": "#10141C",
            "tabActiveBackground": "#151A24", "selection": "#242C3C",
            "hover": "#1D2431", "borderSubtle": "#262E3E",
            "borderStrong": "#333D52",
            "cardBackground": "#1B212D", "fieldBackground": "#10141C",
            "chipBackground": "#1D2431", "accentSoft": "#E3A85724",
            "textPrimary": "#E7EAF2",
            "textSecondary": "#9AA3B8", "textMuted": "#67718A",
            "accent": "#E3A857", "accentHover": "#EDB96F",
            "onAccent": "#201709", "focusRing": "#E3A85766",
            "error": "#E06C75", "warning": "#D4A24E",
            "info": "#82A7F0", "success": "#7CC08A",
            "remoteIndicator": "#74BFCB"
          },
          "editor": {
            "background": "#151A24", "foreground": "#E7EAF2",
            "cursor": "#E3A857", "selectionBackground": "#2C3A55",
            "inactiveSelectionBackground": "#232C3E", "lineHighlight": "#1A2030",
            "gutterBackground": "#151A24", "gutterForeground": "#4B5670",
            "gutterActiveForeground": "#9AA3B8", "indentGuide": "#232B3B",
            "indentGuideActive": "#3A455C", "matchingBracketBorder": "#E3A857",
            "findMatchBackground": "#E3A8573D", "findMatchActiveBackground": "#E3A85766",
            "whitespace": "#2C3547", "rulerBorder": "#262E3E"
          },
          "git": {
            "added": "#7CC08A", "modified": "#D2B958", "deleted": "#E06C75",
            "renamed": "#74BFCB", "untracked": "#6FAECB", "ignored": "#67718A",
            "conflict": "#C678DD", "staged": "#7CC08A"
          },
          "diff": {
            "addedBackground": "#142E1D", "removedBackground": "#331D20",
            "addedGutter": "#7CC08A", "removedGutter": "#E06C75",
            "addedWordBackground": "#1E4A2C", "removedWordBackground": "#4E2A2E"
          },
          "syntax": {
            "comment": { "color": "#5F6980", "fontStyle": "italic" },
            "docComment": { "color": "#6E7890", "fontStyle": "italic" },
            "string": { "color": "#9FC98F" },
            "escape": { "color": "#74BFCB" },
            "number": { "color": "#E0B36A" },
            "constant": { "color": "#E3A857" },
            "keyword": { "color": "#9D8CE8" },
            "operator": { "color": "#98A6C4" },
            "punctuation": { "color": "#6E7A94" },
            "function": { "color": "#74BFCB" },
            "type": { "color": "#82A7F0" },
            "variable": { "color": "#E7EAF2" },
            "parameter": { "color": "#C9D2E6" },
            "property": { "color": "#B8C2DC" },
            "tag": { "color": "#E08D8D" },
            "attribute": { "color": "#D2B958" },
            "namespace": { "color": "#A9B4CE" },
            "markup.heading": { "color": "#E3A857", "fontStyle": "bold" },
            "markup.bold": { "fontStyle": "bold" },
            "markup.italic": { "fontStyle": "italic" },
            "markup.link": { "color": "#74BFCB", "underline": true },
            "markup.code": { "color": "#9FC98F", "background": "#1B212D" },
            "markup.quote": { "color": "#9AA3B8", "fontStyle": "italic" },
            "markup.list": { "color": "#98A6C4" }
          }
        }
        """
    }

    /// Full copy-paste prompt for use in an external chatbot.
    static func clipboardPrompt(description: String) -> String {
        instruction + "\n\n" + userPrompt(description: description)
            + "\n\nAfter generating, save the JSON to a file and import it in "
            + "Rafu via Settings → Appearance → Import JSON."
    }

    /// Extracts the JSON object from a model response that may include
    /// Markdown fences or stray prose.
    static func extractJSON(from response: String) -> Data? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            return trimmed.data(using: .utf8)
        }
        guard let start = trimmed.firstIndex(of: "{"),
            let end = trimmed.lastIndex(of: "}"), start < end
        else { return nil }
        return String(trimmed[start...end]).data(using: .utf8)
    }
}
