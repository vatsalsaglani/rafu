import AppKit
import Foundation
import Neon

@MainActor
struct SyntaxHighlighter {
    let theme: RafuTheme
    let fileExtension: String
    let fileName: String

    init(theme: RafuTheme, fileExtension: String, fileName: String = "") {
        self.theme = theme
        self.fileExtension = fileExtension.lowercased()
        self.fileName = fileName.lowercased()
    }

    func apply(to storage: NSTextStorage) {
        applyBaseStyle(to: storage)

        for token in tokenApplication(
            in: storage.string,
            targetRange: NSRange(location: 0, length: storage.length)
        ).tokens {
            storage.addAttributes(attributes(for: token), range: token.range)
        }
    }

    /// Base editor font resolved from the theme's `fonts.editor` block.
    var baseFont: NSFont { theme.resolvedEditorFont() }

    func applyBaseStyle(to storage: NSTextStorage) {
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.setAttributes(
            [
                .font: baseFont,
                .foregroundColor: NSColor(rafuHex: theme.editor.foreground),
            ],
            range: fullRange
        )
    }

    func tokenApplication(in text: String, targetRange: NSRange) -> TokenApplication {
        let textLength = (text as NSString).length
        guard textLength > 0 else { return .noChange }
        let clampedTarget = NSIntersectionRange(
            targetRange,
            NSRange(location: 0, length: textLength)
        )
        let scanStart = max(0, clampedTarget.location - 512)
        let scanEnd = min(textLength, NSMaxRange(clampedTarget) + 512)
        let scanRange = NSRange(location: scanStart, length: max(0, scanEnd - scanStart))
        var tokens: [Token] = []

        for rule in rules {
            guard let expression = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            expression.enumerateMatches(in: text, range: scanRange) { match, _, _ in
                guard let match else { return }
                let range = match.range(at: rule.captureGroup)
                guard range.location != NSNotFound else { return }
                tokens.append(Token(name: rule.token, range: range))
            }
        }
        return TokenApplication(tokens: tokens, range: scanRange)
    }

    func attributes(for token: Token) -> [NSAttributedString.Key: Any] {
        guard let rule = theme.syntax[token.name] else { return [:] }
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let color = rule.color {
            attributes[.foregroundColor] = NSColor(rafuHex: color)
        }
        if let background = rule.background {
            attributes[.backgroundColor] = NSColor(rafuHex: background)
        }
        if rule.fontStyle == "bold" {
            attributes[.font] = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        } else if rule.fontStyle == "italic" {
            attributes[.font] = NSFontManager.shared.convert(
                baseFont,
                toHaveTrait: .italicFontMask
            )
        }
        if rule.underline == true { attributes[.underlineStyle] = 1 }
        return attributes
    }

    var styleSignature: String {
        let syntax = theme.syntax.sorted(by: { $0.key < $1.key }).map { key, value in
            "\(key):\(value.color ?? ""):\(value.fontStyle ?? ""):\(value.underline == true):\(value.background ?? "")"
        }.joined(separator: "|")
        let font = "\(theme.fonts?.editor?.family ?? "system")@\(theme.editorFontSize)"
        return
            "\(theme.name)|\(font)|\(theme.editor.background)|\(theme.editor.foreground)|\(fileExtension)|\(fileName)|\(syntax)"
    }

    private var keywordPattern: String {
        let words: [String]
        switch fileExtension {
        case "py", "pyw":
            words = [
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
                "del", "elif", "else", "except", "False", "finally", "for", "from", "global",
                "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass",
                "raise", "return", "True", "try", "while", "with", "yield",
            ]
        case "js", "jsx", "mjs", "cjs", "ts", "tsx":
            words = [
                "async", "await", "break", "case", "catch", "class", "const", "continue",
                "debugger", "default", "delete", "do", "else", "export", "extends", "false",
                "finally", "for", "from", "function", "if", "implements", "import", "in",
                "instanceof", "interface", "let", "new", "null", "of", "private", "protected",
                "public", "return", "static", "super", "switch", "this", "throw", "true", "try",
                "type", "typeof", "undefined", "var", "void", "while", "with", "yield",
            ]
        case "rs":
            words = [
                "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else",
                "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop",
                "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static",
                "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while",
            ]
        case "go":
            words = [
                "break", "case", "chan", "const", "continue", "default", "defer", "else",
                "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
                "package", "range", "return", "select", "struct", "switch", "type", "var",
            ]
        case "sh", "bash", "zsh", "fish":
            words = [
                "case", "do", "done", "elif", "else", "end", "esac", "export", "fi", "for",
                "function", "if", "in", "local", "readonly", "select", "set", "source", "then",
                "time", "until", "while",
            ]
        case "rb":
            words = [
                "alias", "begin", "break", "case", "class", "def", "defined", "do", "else",
                "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil",
                "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef",
                "unless", "until", "when", "while", "yield",
            ]
        case "java", "kt", "kts", "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm":
            words = [
                "abstract", "auto", "break", "case", "catch", "class", "const", "continue",
                "default", "do", "else", "enum", "extends", "false", "final", "for", "fun",
                "if", "implements", "import", "instanceof", "interface", "namespace", "new", "null",
                "override", "package", "private", "protected", "public", "return", "static",
                "struct",
                "super", "switch", "this", "throw", "throws", "true", "try", "typedef", "using",
                "val", "var", "virtual", "void", "volatile", "when", "while",
            ]
        case "sql":
            words = [
                "ALTER", "AND", "AS", "ASC", "BEGIN", "BETWEEN", "BY", "CASE", "CREATE",
                "DELETE", "DESC", "DISTINCT", "DROP", "ELSE", "END", "EXISTS", "FROM", "GROUP",
                "HAVING", "IN", "INNER", "INSERT", "INTO", "IS", "JOIN", "LEFT", "LIKE", "LIMIT",
                "NOT", "NULL", "ON", "OR", "ORDER", "OUTER", "RIGHT", "SELECT", "SET", "TABLE",
                "THEN", "UNION", "UPDATE", "VALUES", "WHEN", "WHERE", "WITH",
            ]
        default:
            words = [
                "actor", "async", "await", "break", "case", "catch", "class", "const", "continue",
                "default", "defer", "do", "else", "enum", "extension", "false", "final", "for",
                "func", "guard", "if", "import", "in", "init", "let", "nil", "null", "private",
                "protocol", "public", "return", "static", "struct", "switch", "throw", "throws",
                "true", "try", "var", "while",
            ]
        }
        return #"(?i:\b(?:"# + words.map(NSRegularExpression.escapedPattern).joined(separator: "|")
            + #")\b)"#
    }

    private var rules: [Rule] {
        // Rule order matters: later rules override earlier attributes, so
        // strings/doc comments/comments come last to win inside their spans.
        var rules: [Rule] = [
            Rule(#"[+\-*/%=<>!&|^~]{1,3}"#, "operator"),
            Rule(#"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"#, "number"),
            Rule(keywordPattern, "keyword"),
        ]
        if isCodeFile {
            rules.insert(
                contentsOf: [
                    Rule(#"\b[A-Z][A-Za-z0-9_]*\b"#, "type"),
                    Rule(#"\b[A-Z][A-Z0-9_]{2,}\b"#, "constant"),
                    Rule(#"@[A-Za-z_]\w*"#, "attribute"),
                    Rule(
                        #"\b(?!(?:if|for|while|switch|catch|guard|return|in|do|else)\b)([a-z_][\w]*)\s*\("#,
                        "function", captureGroup: 1),
                ], at: 0)
        }
        if ["md", "markdown"].contains(fileExtension) {
            rules.append(contentsOf: [
                Rule(#"(?m)^#{1,6}\s+.*$"#, "markup.heading"),
                Rule(#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, "markup.bold"),
                Rule(#"(?<![*_\w])[*_][^*_\n]+[*_](?![*_\w])"#, "markup.italic"),
                Rule(#"(?m)^\s*(?:[-*+]|\d+\.)\s"#, "markup.list"),
                Rule(#"(?m)^>.*$"#, "markup.quote"),
                Rule(#"`[^`\n]+`"#, "markup.code"),
                Rule(#"\[[^\]]+\]\([^\)]+\)"#, "markup.link"),
            ])
        }
        if ["swift", "py", "pyw", "js", "jsx", "mjs", "cjs", "ts", "tsx", "rs", "go", "rb"]
            .contains(fileExtension)
        {
            rules.append(
                Rule(
                    #"\b(?:func|def|function|fn)\s+([A-Za-z_$][\w$]*)"#, "function", captureGroup: 1
                ))
        }
        if ["html", "htm", "xml", "svg", "vue", "svelte", "jsx", "tsx"].contains(fileExtension) {
            rules.append(contentsOf: [
                Rule(#"</?([A-Za-z][A-Za-z0-9:._-]*)"#, "tag", captureGroup: 1),
                Rule(#"\s([A-Za-z_:][A-Za-z0-9:._-]*)(?=\s*=)"#, "attribute", captureGroup: 1),
            ])
        }
        if ["css", "scss", "sass", "less"].contains(fileExtension) {
            rules.append(Rule(#"(?m)^\s*([\w-]+)\s*:"#, "property", captureGroup: 1))
        }
        if ["json", "jsonc"].contains(fileExtension) {
            rules.append(Rule(#"\"([^\"\\]+)\"(?=\s*:)"#, "property", captureGroup: 1))
        }
        if ["yaml", "yml", "toml", "ini", "env"].contains(fileExtension)
            || fileName.hasSuffix(".env")
        {
            rules.append(contentsOf: [
                Rule(
                    #"(?m)^\s*([A-Za-z_][A-Za-z0-9_.-]*)\s*(?=[:=])"#, "property", captureGroup: 1),
                Rule(#"(?i:\b(?:true|false|null|yes|no|on|off)\b)"#, "constant"),
            ])
        }
        if fileName == "dockerfile" || fileName.hasPrefix("dockerfile.") {
            rules.append(
                Rule(
                    #"(?mi)^\s*(FROM|RUN|CMD|LABEL|EXPOSE|ENV|ADD|COPY|ENTRYPOINT|VOLUME|USER|WORKDIR|ARG|ONBUILD|STOPSIGNAL|HEALTHCHECK|SHELL)\b"#,
                    "keyword", captureGroup: 1))
        }
        if fileName == "makefile" || fileName.hasSuffix(".mk") {
            rules.append(Rule(#"(?m)^([A-Za-z0-9_.%/-]+)\s*:"#, "function", captureGroup: 1))
        }
        // Spans that must win over everything matched above.
        rules.append(contentsOf: [
            Rule(#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, "string"),
            Rule(#"\\(?:[nrt0\\'\"]|u\{[0-9A-Fa-f]+\}|x[0-9A-Fa-f]{2})"#, "escape"),
            Rule(#"(?m)///.*$|/\*\*[\s\S]*?\*/"#, "docComment"),
            Rule(#"(?m)//(?!/).*$|/\*(?!\*)[\s\S]*?\*/|(?m)^\s*#(?!\w).*$"#, "comment"),
        ])
        return rules
    }

    private var isCodeFile: Bool {
        [
            "swift", "py", "pyw", "js", "jsx", "mjs", "cjs", "ts", "tsx", "rs", "go", "rb",
            "java", "kt", "kts", "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm", "cs", "php",
        ].contains(fileExtension)
    }

    private struct Rule {
        let pattern: String
        let token: String
        let captureGroup: Int

        init(_ pattern: String, _ token: String, captureGroup: Int = 0) {
            self.pattern = pattern
            self.token = token
            self.captureGroup = captureGroup
        }
    }
}

@MainActor
final class NeonSyntaxHighlightingPipeline: NSObject {
    private final class Configuration {
        var highlighter: SyntaxHighlighter

        init(highlighter: SyntaxHighlighter) {
            self.highlighter = highlighter
        }
    }

    private weak var textView: NSTextView?
    private let configuration: Configuration
    private let highlighter: Highlighter

    init(textView: NSTextView, theme: RafuTheme, fileExtension: String, fileName: String = "") {
        let syntaxHighlighter = SyntaxHighlighter(
            theme: theme, fileExtension: fileExtension, fileName: fileName)
        let configuration = Configuration(highlighter: syntaxHighlighter)
        self.configuration = configuration
        self.textView = textView

        let interface = TextViewSystemInterface(textView: textView) { token in
            configuration.highlighter.attributes(for: token)
        }
        highlighter = Highlighter(textInterface: interface) { [weak textView] range, completion in
            guard let textView else {
                completion(.success(.noChange))
                return
            }
            let application = configuration.highlighter.tokenApplication(
                in: textView.string,
                targetRange: range
            )
            completion(.success(application))
        }
        highlighter.requestLengthLimit = 4_096
        highlighter.visibleLookAheadLength = 2_048
        highlighter.visibleLookBehindLength = 2_048

        super.init()
        textView.enclosingScrollView?.postsFrameChangedNotifications = true
        textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
        if let scrollView = textView.enclosingScrollView {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(visibleContentChanged),
                name: NSView.frameDidChangeNotification,
                object: scrollView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(visibleContentChanged),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }
        applyBaseStyleAndInvalidate()
    }

    func update(theme: RafuTheme, fileExtension: String, fileName: String = "") {
        let next = SyntaxHighlighter(
            theme: theme, fileExtension: fileExtension, fileName: fileName)
        guard next.styleSignature != configuration.highlighter.styleSignature else { return }
        configuration.highlighter = next
        applyBaseStyleAndInvalidate()
    }

    func didProcessEditing(
        editedMask: NSTextStorageEditActions,
        editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        let previousRange = NSRange(
            location: editedRange.location,
            length: max(0, editedRange.length - delta)
        )
        highlighter.didChangeContent(in: previousRange, delta: delta)
        highlighter.invalidate(.range(editedRange))
    }

    func applyBaseStyleAndInvalidate() {
        guard let storage = textView?.textStorage else { return }
        configuration.highlighter.applyBaseStyle(to: storage)
        highlighter.invalidate(.all)
    }

    @objc private func visibleContentChanged() {
        highlighter.visibleContentDidChange()
    }
}
