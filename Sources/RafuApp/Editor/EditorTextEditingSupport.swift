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
