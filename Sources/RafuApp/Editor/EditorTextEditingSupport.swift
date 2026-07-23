import Foundation

/// Pure bracket-pair scanning for the caret-adjacent highlight. Operates on
/// UTF-16 offsets so results map directly onto `NSTextView` ranges.
nonisolated enum BracketMatcher {
    /// Upper bound on scanned UTF-16 units so pathological buffers cannot
    /// stall the main thread during selection changes.
    static let scanLimit = 100_000

    private static let pairs: [unichar: unichar] = [
        unichar(UInt8(ascii: "(")): unichar(UInt8(ascii: ")")),
        unichar(UInt8(ascii: "[")): unichar(UInt8(ascii: "]")),
        unichar(UInt8(ascii: "{")): unichar(UInt8(ascii: "}")),
    ]

    private static let reversePairs: [unichar: unichar] = [
        unichar(UInt8(ascii: ")")): unichar(UInt8(ascii: "(")),
        unichar(UInt8(ascii: "]")): unichar(UInt8(ascii: "[")),
        unichar(UInt8(ascii: "}")): unichar(UInt8(ascii: "{")),
    ]

    /// Returns the single-character ranges of the bracket adjacent to the
    /// caret and its match, or `nil` when the caret touches no bracket or the
    /// match is unbalanced/beyond the scan limit. The character before the
    /// caret wins over the character after it.
    static func matchedRanges(in text: String, caretLocation: Int) -> [NSRange]? {
        let nsText = text as NSString
        guard caretLocation >= 0, caretLocation <= nsText.length else { return nil }

        for candidate in [caretLocation - 1, caretLocation] {
            guard candidate >= 0, candidate < nsText.length else { continue }
            let character = nsText.character(at: candidate)
            if let closing = pairs[character] {
                guard
                    let match = scanForward(
                        in: nsText, from: candidate, opening: character, closing: closing)
                else { continue }
                return [
                    NSRange(location: candidate, length: 1), NSRange(location: match, length: 1),
                ]
            }
            if let opening = reversePairs[character] {
                guard
                    let match = scanBackward(
                        in: nsText, from: candidate, opening: opening, closing: character)
                else { continue }
                return [
                    NSRange(location: match, length: 1), NSRange(location: candidate, length: 1),
                ]
            }
        }
        return nil
    }

    private static func scanForward(
        in text: NSString, from start: Int, opening: unichar, closing: unichar
    ) -> Int? {
        var depth = 0
        var index = start
        let limit = min(text.length, start + scanLimit)
        while index < limit {
            let character = text.character(at: index)
            if character == opening {
                depth += 1
            } else if character == closing {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    private static func scanBackward(
        in text: NSString, from start: Int, opening: unichar, closing: unichar
    ) -> Int? {
        var depth = 0
        var index = start
        let limit = max(0, start - scanLimit)
        while index >= limit {
            let character = text.character(at: index)
            if character == closing {
                depth += 1
            } else if character == opening {
                depth -= 1
                if depth == 0 { return index }
            }
            index -= 1
        }
        return nil
    }
}

/// Pure "wrap selection in matching bracket pair" logic (issue #5a): typing
/// an opening bracket/quote while text is selected wraps the selection
/// instead of replacing it, leaving the original text selected — matching
/// VS Code's `editor.autoSurround`. `RafuTextView.insertText(_:replacementRange:)`
/// is the only caller.
nonisolated enum BracketWrap {
    static let pairs: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "<": ">",
        "\"": "\"", "'": "'", "`": "`",
    ]

    struct Result: Equatable, Sendable {
        /// The full replacement text: `opening` + `selection` + `closing`.
        let text: String
        /// The UTF-16 range the ORIGINAL selection occupies inside `text`,
        /// so the caller can reselect exactly the wrapped content.
        let innerRange: NSRange
    }

    /// `nil` when `opening` has no configured closing pair.
    static func wrapping(selection: String, opening: Character) -> Result? {
        guard let closing = pairs[opening] else { return nil }
        let text = String(opening) + selection + String(closing)
        let innerLength = (selection as NSString).length
        return Result(text: text, innerRange: NSRange(location: 1, length: innerLength))
    }
}

nonisolated struct LineCommentToggle: Equatable, Sendable {
    let replacement: String
    let didComment: Bool
}

/// Pure line-comment toggling. The caller supplies the whole-line substring
/// covered by the selection and applies the returned replacement.
nonisolated enum LineCommenter {
    /// Line-comment prefix for a file, or `nil` when the language has no line
    /// comments (HTML, CSS, Markdown, JSON) so ⌘/ is a no-op.
    static func prefix(forExtension fileExtension: String, fileName: String = "") -> String? {
        let lowerName = fileName.lowercased()
        if lowerName == "dockerfile" || lowerName.hasPrefix("dockerfile.")
            || lowerName == "makefile" || lowerName.hasSuffix(".mk")
            || lowerName == ".env" || lowerName.hasPrefix(".env.")
        {
            return "#"
        }
        switch fileExtension.lowercased() {
        case "swift", "js", "jsx", "mjs", "cjs", "ts", "tsx", "c", "h", "cc", "cpp", "cxx",
            "hpp", "m", "mm", "go", "rs", "java", "kt", "kts", "scala", "cs", "php", "dart",
            "proto", "groovy":
            return "//"
        case "py", "pyw", "sh", "bash", "zsh", "fish", "rb", "yaml", "yml", "toml", "ini",
            "env", "conf", "r", "pl", "tcl", "cmake", "nix", "ps1":
            return "#"
        case "sql", "lua", "hs":
            return "--"
        default:
            return nil
        }
    }

    /// Toggles `prefix` on every non-blank line of `lines`. When every
    /// non-blank line already starts (after indentation) with the prefix the
    /// prefixes are removed; otherwise `prefix + " "` is inserted at the
    /// minimum common indentation column. Blank lines are left untouched
    /// unless every line is blank.
    static func toggle(lines: String, prefix: String) -> LineCommentToggle {
        let endsWithNewline = lines.hasSuffix("\n")
        var components = lines.components(separatedBy: "\n")
        if endsWithNewline { components.removeLast() }

        let contentIndices = components.indices.filter {
            !components[$0].trimmingCharacters(in: .whitespaces).isEmpty
        }

        if contentIndices.isEmpty {
            // Only blank lines: comment each one at column zero.
            let replaced = components.map { $0 + prefix + " " }
            return LineCommentToggle(
                replacement: joined(replaced, endsWithNewline: endsWithNewline),
                didComment: true
            )
        }

        let allCommented = contentIndices.allSatisfy { index in
            components[index].drop(while: { $0 == " " || $0 == "\t" }).hasPrefix(prefix)
        }

        if allCommented {
            for index in contentIndices {
                let line = components[index]
                let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
                var rest = line.dropFirst(indent.count)
                rest = rest.dropFirst(prefix.count)
                if rest.first == " " { rest = rest.dropFirst() }
                components[index] = String(indent) + rest
            }
            return LineCommentToggle(
                replacement: joined(components, endsWithNewline: endsWithNewline),
                didComment: false
            )
        }

        let minimumIndent =
            contentIndices
            .map { components[$0].prefix(while: { $0 == " " || $0 == "\t" }).count }
            .min() ?? 0
        for index in contentIndices {
            let line = components[index]
            let insertion = line.index(line.startIndex, offsetBy: minimumIndent)
            components[index] =
                String(line[..<insertion]) + prefix + " " + String(line[insertion...])
        }
        return LineCommentToggle(
            replacement: joined(components, endsWithNewline: endsWithNewline),
            didComment: true
        )
    }

    private static func joined(_ components: [String], endsWithNewline: Bool) -> String {
        components.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
    }
}

/// A language's block-comment open/close delimiters (e.g. `/*`/`*/`,
/// `<!--`/`-->`). `nil` in `CommentSyntax.block` means the language has no
/// block-comment syntax Rafu knows about.
nonisolated struct BlockCommentDelimiters: Equatable, Sendable {
    let open: String
    let close: String
}

/// A file's comment syntax: an optional line-comment token
/// (`LineCommenter.prefix`) and an optional block-comment delimiter pair.
/// Both can be present (most C-family languages); a markup language may
/// have only a block form; a data format with no comment syntax (plain
/// JSON) has neither, and ⌘/ stays a no-op.
nonisolated struct CommentSyntax: Equatable, Sendable {
    let line: String?
    let block: BlockCommentDelimiters?
}

/// Static, per-language comment-syntax lookup (issue #5b). Tree-sitter has
/// no cheap "comment token" query across grammars, so this table is the
/// source of truth `CodeEditorView.Coordinator.toggleLineComment()` reads to
/// choose between `LineCommenter` and `BlockCommenter`.
nonisolated enum CommentSyntaxTable {
    static func syntax(forExtension fileExtension: String, fileName: String = "") -> CommentSyntax {
        CommentSyntax(
            line: LineCommenter.prefix(forExtension: fileExtension, fileName: fileName),
            block: blockDelimiters(forExtension: fileExtension)
        )
    }

    private static func blockDelimiters(forExtension fileExtension: String)
        -> BlockCommentDelimiters?
    {
        switch fileExtension.lowercased() {
        case "html", "htm", "xml", "svg", "vue", "md", "markdown":
            return BlockCommentDelimiters(open: "<!--", close: "-->")
        case "css", "scss", "less", "swift", "js", "jsx", "mjs", "cjs", "ts", "tsx", "c", "h",
            "cc", "cpp", "cxx", "hpp", "m", "mm", "go", "rs", "java", "kt", "kts", "scala", "cs",
            "php", "dart", "proto", "groovy":
            return BlockCommentDelimiters(open: "/*", close: "*/")
        default:
            return nil
        }
    }
}

nonisolated struct BlockCommentToggle: Equatable, Sendable {
    let replacement: String
    let didComment: Bool
}

/// Pure block-comment toggling for a single selection or the current line
/// (the caller supplies the exact substring to toggle). Complements
/// `LineCommenter` for languages whose only ⌘/ comment form is a block
/// delimiter pair (e.g. CSS, HTML).
nonisolated enum BlockCommenter {
    /// Wraps `selection` in `open`/`close` (with one padding space each), or
    /// unwraps it when it already starts with `open` and ends with `close`.
    static func toggle(selection: String, open: String, close: String) -> BlockCommentToggle {
        if selection.hasPrefix(open), selection.hasSuffix(close),
            selection.count >= open.count + close.count
        {
            var inner = String(selection.dropFirst(open.count).dropLast(close.count))
            if inner.hasPrefix(" ") { inner.removeFirst() }
            if inner.hasSuffix(" ") { inner.removeLast() }
            return BlockCommentToggle(replacement: inner, didComment: false)
        }
        return BlockCommentToggle(replacement: "\(open) \(selection) \(close)", didComment: true)
    }
}

/// The result of a `LineManipulation` transform: a single `NSTextStorage`
/// replacement plus the selection the caller should restore afterward.
/// `nil` from any `LineManipulation` function means the transform is a no-op
/// at the buffer's edge (e.g. moving the first line up).
nonisolated struct LineEdit: Equatable, Sendable {
    let replacementRange: NSRange
    let replacementText: String
    let newSelection: NSRange
}

/// Pure move/duplicate/delete-line transforms (VS Code's Option+Up/Down,
/// Shift+Option+Up/Down, and ⌘⇧K). Every function starts from
/// `NSString.lineRange(for:)` to find the whole-line block the selection
/// touches, so a multi-line selection moves/duplicates/deletes as one unit.
/// All Foundation line APIs used here (`lineRange(for:)`,
/// `getLineStart(_:end:contentsEnd:for:)`) already treat "\n", "\r", and
/// "\r\n" as a single line terminator, so CRLF documents round-trip
/// correctly with no special-casing.
nonisolated enum LineManipulation {
    /// Moves the selection's line block up by one line, swapping it with the
    /// preceding line. `nil` when the block already starts at the first line.
    static func moveUp(text: String, selection: NSRange) -> LineEdit? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let selection = clamped(selection, to: ns.length)
        let blockRange = ns.lineRange(for: selection)
        guard blockRange.location > 0 else { return nil }

        let prevLineRange = ns.lineRange(for: NSRange(location: blockRange.location - 1, length: 0))
        let combinedRange = NSRange(
            location: prevLineRange.location,
            length: NSMaxRange(blockRange) - prevLineRange.location
        )
        let (blockBody, blockTerm) = decomposeLine(blockRange, in: ns)
        let (prevBody, prevTerm) = decomposeLine(prevLineRange, in: ns)
        let replacementText = blockBody + prevTerm + prevBody + blockTerm

        let offsetInBlock = selection.location - blockRange.location
        let newSelection = NSRange(
            location: combinedRange.location + offsetInBlock, length: selection.length)
        return LineEdit(
            replacementRange: combinedRange, replacementText: replacementText,
            newSelection: newSelection)
    }

    /// Moves the selection's line block down by one line, swapping it with
    /// the following line. `nil` when the block already reaches end of file.
    static func moveDown(text: String, selection: NSRange) -> LineEdit? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let selection = clamped(selection, to: ns.length)
        let blockRange = ns.lineRange(for: selection)
        guard NSMaxRange(blockRange) < ns.length else { return nil }

        let nextLineRange = ns.lineRange(for: NSRange(location: NSMaxRange(blockRange), length: 0))
        let combinedRange = NSRange(
            location: blockRange.location,
            length: NSMaxRange(nextLineRange) - blockRange.location
        )
        let (blockBody, blockTerm) = decomposeLine(blockRange, in: ns)
        let (nextBody, nextTerm) = decomposeLine(nextLineRange, in: ns)
        let replacementText = nextBody + blockTerm + blockBody + nextTerm

        let offsetInBlock = selection.location - blockRange.location
        let prefixLength = (nextBody as NSString).length + (blockTerm as NSString).length
        let newSelection = NSRange(
            location: combinedRange.location + prefixLength + offsetInBlock,
            length: selection.length)
        return LineEdit(
            replacementRange: combinedRange, replacementText: replacementText,
            newSelection: newSelection)
    }

    /// Inserts a copy of the selection's line block immediately above it.
    /// The selection itself is left unchanged: since the inserted copy is
    /// identical to the original block, the caret lands on the same visible
    /// content either way.
    static func duplicateAbove(text: String, selection: NSRange) -> LineEdit? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let selection = clamped(selection, to: ns.length)
        let blockRange = ns.lineRange(for: selection)
        let (blockBody, blockTerm) = decomposeLine(blockRange, in: ns)
        let insertionText = blockBody + (blockTerm.isEmpty ? "\n" : blockTerm)
        return LineEdit(
            replacementRange: NSRange(location: blockRange.location, length: 0),
            replacementText: insertionText,
            newSelection: selection)
    }

    /// Inserts a copy of the selection's line block immediately below it and
    /// moves the selection into the new (duplicate) copy, matching VS Code's
    /// Copy Line Down.
    static func duplicateBelow(text: String, selection: NSRange) -> LineEdit? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let selection = clamped(selection, to: ns.length)
        let blockRange = ns.lineRange(for: selection)
        let (blockBody, blockTerm) = decomposeLine(blockRange, in: ns)
        let insertionText = blockTerm.isEmpty ? "\n" + blockBody : blockBody + blockTerm
        let insertionLength = (insertionText as NSString).length
        let newSelection = NSRange(
            location: selection.location + insertionLength, length: selection.length)
        return LineEdit(
            replacementRange: NSRange(location: NSMaxRange(blockRange), length: 0),
            replacementText: insertionText,
            newSelection: newSelection)
    }

    /// Deletes the selection's whole line block. When the block is the
    /// file's final line with no trailing terminator, the preceding line's
    /// terminator is absorbed into the deletion too, so no blank line is
    /// left dangling at the end of the file. The new caret keeps its
    /// original column on the line that now occupies the deleted block's
    /// position, clamped to that line's length.
    static func deleteLines(text: String, selection: NSRange) -> LineEdit? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let selection = clamped(selection, to: ns.length)
        let blockRange = ns.lineRange(for: selection)
        let column = selection.location - blockRange.location

        var deletionRange = blockRange
        let (_, blockTerm) = decomposeLine(blockRange, in: ns)
        if NSMaxRange(blockRange) == ns.length, blockTerm.isEmpty, blockRange.location > 0 {
            var precedingContentsEnd = 0
            ns.getLineStart(
                nil, end: nil, contentsEnd: &precedingContentsEnd,
                for: NSRange(location: blockRange.location - 1, length: 0))
            deletionRange = NSRange(
                location: precedingContentsEnd,
                length: NSMaxRange(blockRange) - precedingContentsEnd)
        }

        let newLength = ns.length - deletionRange.length
        let caretBase = min(deletionRange.location, newLength)
        let newText = ns.replacingCharacters(in: deletionRange, with: "") as NSString
        let newLineRange = newText.lineRange(for: NSRange(location: caretBase, length: 0))
        let (newLineBody, _) = decomposeLine(newLineRange, in: newText)
        let clampedColumn = min(column, (newLineBody as NSString).length)
        let newSelection = NSRange(
            location: newLineRange.location + clampedColumn, length: 0)
        return LineEdit(
            replacementRange: deletionRange, replacementText: "", newSelection: newSelection)
    }

    /// Splits `range` into its content (everything up to but excluding the
    /// final line's terminator) and that terminator (`""` when `range` ends
    /// at end-of-file with no trailing newline). `range` may span multiple
    /// physical lines; internal line terminators stay part of the content.
    private static func decomposeLine(_ range: NSRange, in ns: NSString) -> (
        content: String, terminator: String
    ) {
        guard range.length > 0 else { return ("", "") }
        var contentsEnd = 0
        ns.getLineStart(
            nil, end: nil, contentsEnd: &contentsEnd,
            for: NSRange(location: NSMaxRange(range) - 1, length: 0))
        let content = ns.substring(
            with: NSRange(location: range.location, length: contentsEnd - range.location))
        let terminator = ns.substring(
            with: NSRange(location: contentsEnd, length: NSMaxRange(range) - contentsEnd))
        return (content, terminator)
    }

    private static func clamped(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        let len = min(max(range.length, 0), length - location)
        return NSRange(location: location, length: len)
    }
}

/// Pure newline auto-indentation: copy the caret line's leading whitespace and
/// add one level after a block opener.
nonisolated enum AutoIndenter {
    /// The string to insert instead of a plain "\n" at `caretLocation`
    /// (a UTF-16 offset). Adds one indent level when the text before the
    /// caret ends with "{" (or ":" for Python files). The extra level uses a
    /// tab when the current line already indents with tabs, else four spaces.
    static func newlineInsertion(
        forCaretAt caretLocation: Int,
        in text: String,
        fileExtension: String
    ) -> String {
        let nsText = text as NSString
        let clamped = max(0, min(caretLocation, nsText.length))
        let lineRange = nsText.lineRange(for: NSRange(location: clamped, length: 0))
        let head = nsText.substring(
            with: NSRange(location: lineRange.location, length: clamped - lineRange.location)
        )
        var indent = String(head.prefix(while: { $0 == " " || $0 == "\t" }))
        let trimmed = head.trimmingCharacters(in: .whitespaces)
        let isPython = ["py", "pyw"].contains(fileExtension.lowercased())
        if trimmed.hasSuffix("{") || (isPython && trimmed.hasSuffix(":")) {
            indent += indent.contains("\t") ? "\t" : "    "
        }
        return "\n" + indent
    }
}
