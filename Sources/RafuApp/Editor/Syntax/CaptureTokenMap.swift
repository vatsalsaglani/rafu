import Foundation

/// Full tree-sitter capture-name → `RafuTheme.syntax` key adapter for
/// lane-1 increment 9 (plan §7.3 "Semantic token model and Tree-sitter
/// mapping"). The vendored `highlights.scm`/`tags.scm` queries use
/// nvim-treesitter-style dotted capture names (`keyword.function`,
/// `variable.parameter`, `comment.documentation`, …); `RafuTheme.syntax` is
/// keyed on flat names (`keyword`, `parameter`, `docComment`, …) that
/// `SyntaxHighlighter.attributes(for:)` resolves. This bridges the two,
/// replacing 8a's minimal `SyntaxCaptureMap`.
///
/// Resolution is longest-prefix: a capture is split on `.` and probed from
/// its full dotted name down to its root, dropping one trailing component at
/// a time, so a specific row (`string.escape` → `escape`) always wins over a
/// broader root row (`string` → `string`) without needing every dotted
/// variant spelled out. A capture with no mapping at any level returns
/// `nil`, so its span is dropped and the text keeps the theme's base
/// foreground — never a crash, never a blank line.
nonisolated enum CaptureTokenMap {
    /// The `RafuTheme.syntax` key for a tree-sitter highlight/tag capture
    /// name, or `nil` when no row in `captureToToken` (at any prefix depth)
    /// covers it.
    static func themeKey(forCapture capture: String) -> String? {
        var components = capture.split(separator: ".").map(String.init)
        while !components.isEmpty {
            if let token = captureToToken[components.joined(separator: ".")] {
                return token
            }
            components.removeLast()
        }
        return nil
    }

    /// Plan §7.3's capture→token table, at table granularity, plus a small
    /// theme-supported superset kept from 8a's `SyntaxCaptureMap`
    /// (`comment.documentation` → `docComment`, `constructor` → `type`,
    /// `variable.member`/`field` → `property`) — every target here is an
    /// existing `RafuTheme.syntax` key (see `CaptureTokenMapTests`).
    private static let captureToToken: [String: String] = [
        // @comment, @comment.documentation
        "comment": "comment",
        "comment.documentation": "docComment",

        // @string, @string.special / @string.escape
        "string": "string",
        "string.special": "string",
        "string.escape": "escape",
        "escape": "escape",

        // @number, @float
        "number": "number",
        "float": "number",

        // @constant, @constant.builtin, @boolean
        "constant": "constant",
        "constant.builtin": "constant",
        "boolean": "constant",

        // @keyword, @keyword.*
        "keyword": "keyword",

        // @operator
        "operator": "operator",

        // @punctuation.*
        "punctuation": "punctuation",

        // @function, @function.call, @function.method
        "function": "function",
        "function.call": "function",
        "function.method": "function",

        // @type, @type.builtin
        "type": "type",
        "type.builtin": "type",
        // Superset kept from 8a: a named constructor/initializer reads as a
        // type reference in the editor.
        "constructor": "type",

        // @variable
        "variable": "variable",
        // @variable.parameter
        "variable.parameter": "parameter",
        // Superset kept from 8a: some grammars distinguish member/field
        // access from a bare property declaration.
        "variable.member": "property",

        // @property, @field
        "property": "property",
        "field": "property",

        // @tag
        "tag": "tag",

        // @attribute, @tag.attribute
        "attribute": "attribute",
        "tag.attribute": "attribute",

        // @namespace, @module
        "namespace": "namespace",
        "module": "namespace",

        // Markdown/markup rows.
        "markup.heading": "markup.heading",
        "markup.bold": "markup.bold",
        "markup.italic": "markup.italic",
        "markup.link": "markup.link",
        "markup.link.url": "markup.link",
        "markup.raw": "markup.code",
        "markup.quote": "markup.quote",
        "markup.list": "markup.list",

        // markdown_inline's `highlights.scm` (lane symbol-coverage increment
        // D) uses the older nvim `text.*` convention rather than `markup.*`.
        // These rows map it onto the same theme keys as the block-level
        // `markup.*` rows above, so the injected inline pass and the block
        // pass agree on appearance.
        "text.emphasis": "markup.italic",
        "text.strong": "markup.bold",
        "text.literal": "markup.code",
        "text.title": "markup.heading",
        "text.uri": "markup.link",
        "text.reference": "markup.link",
        "text.quote": "markup.quote",
    ]
}
