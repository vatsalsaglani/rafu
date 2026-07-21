import Foundation

/// Pure decision/bounding functions for terminal attention state
/// (terminal-manager.md T-E) — no `AppKit`/`UserNotifications` import, no
/// `NSApp`/window access, so every rule here is headless-testable. Callers
/// gather the booleans (`NSApp.isActive`, a window's `isKeyWindow`, the
/// focused group's selected tab) and pass them in.
nonisolated enum TerminalAttentionPolicy {
    /// "Not focused" = the session's tab is not the focused group's
    /// selected tab, OR the app is not active, OR its window is not key —
    /// any one of those means the user is not looking at this shell right
    /// now. Only a `.running` session can raise attention: `.idle` never
    /// bells (no process yet) and `.exited`/already-`.bell` never re-raise
    /// (mirrors `WorkspaceTerminalController.noteBell()`'s own guard).
    static func shouldRaiseAttention(
        isSelectedTab: Bool,
        isAppActive: Bool,
        isWindowKey: Bool,
        status: TerminalSessionStatus
    ) -> Bool {
        guard status == .running else { return false }
        return !(isSelectedTab && isAppActive && isWindowKey)
    }

    /// A notification only posts when ALL three hold: attention was
    /// actually raised, the user has the preference on, and the OS has
    /// authorized notifications. Denial degrades to the in-app badge only.
    static func shouldNotify(
        raisedAttention: Bool,
        preferenceEnabled: Bool,
        isAuthorized: Bool
    ) -> Bool {
        raisedAttention && preferenceEnabled && isAuthorized
    }

    /// Bounds a notification body to the last few non-empty lines a
    /// terminal had on screen, each capped, the whole capped again —
    /// `RafuTerminalView.recentOutputSnippet` supplies `lines` from the
    /// live viewport (never scrollback); this half is the pure, testable
    /// bounding/sanitizing logic. Every cap truncates on a UTF-8 byte
    /// boundary (the `String(decoding:as:)` idiom used by
    /// `WorkspaceSession.boundedAIErrorMessage`), so a multibyte character
    /// (emoji, etc.) at a boundary is dropped whole, never split.
    static func snippet(
        from lines: [String],
        maxLines: Int = 6,
        maxLineBytes: Int = 200,
        maxBytes: Int = 512
    ) -> String {
        let sanitizedLines = lines.map(sanitizedControlFreeLine)
            .filter { !$0.isEmpty && !isDecorativeRule($0) }
        let kept = sanitizedLines.suffix(maxLines)
        guard !kept.isEmpty else { return "" }
        let bounded = kept.map { boundedUTF8($0, maxBytes: maxLineBytes) }
        return boundedUTF8(bounded.joined(separator: "\n"), maxBytes: maxBytes)
    }

    /// A notification reply is one line, not a script: newlines/carriage
    /// returns collapse to a single space (so a multi-line paste becomes
    /// one space-joined line rather than glued-together words), every other
    /// C0/C1 control character (including ESC and NUL) is dropped outright,
    /// whitespace runs collapse, and the result is capped to `maxBytes` on
    /// a UTF-8 boundary. Returns `nil` for empty/whitespace-only input so
    /// callers can drop it rather than sending a blank line into a live
    /// shell.
    static func sanitizedReply(_ text: String, maxBytes: Int = 1024) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x0D:
                scalars.append(" ")
            case 0, 0x01...0x1F, 0x7F...0x9F:
                continue
            default:
                scalars.append(scalar)
            }
        }
        let trimmed = collapsedWhitespace(String(scalars)).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return boundedUTF8(trimmed, maxBytes: maxBytes)
    }

    /// Strips C0/C1 controls (including ESC, excluding the space/tab this
    /// collapses separately) and NUL, then collapses whitespace runs —
    /// terminal output is presentation, not content Rafu relays verbatim
    /// into a system notification body.
    private static func sanitizedControlFreeLine(_ line: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in line.unicodeScalars {
            switch scalar.value {
            case 0:
                // NUL is a never-written buffer cell, NOT junk: TUIs (claude,
                // codex) position words with cursor movement instead of
                // literal spaces, so the cells BETWEEN words are NUL.
                // Dropping them glued every word together
                // ("Hey!We'reontherafurepo"); they must become spaces, which
                // `collapsedWhitespace` then de-duplicates.
                scalars.append(" ")
            case 0x01...0x1F, 0x7F...0x9F:
                continue
            default:
                scalars.append(scalar)
            }
        }
        return collapsedWhitespace(String(scalars))
    }

    /// Drops purely decorative lines — a TUI's horizontal rules
    /// ("──────…", "-----") — which waste one of the snippet's six lines
    /// saying nothing. Structural check only (repetition of one
    /// non-alphanumeric character), never content interpretation.
    private static func isDecorativeRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 8, let first = trimmed.first, !first.isLetter, !first.isNumber
        else { return false }
        let dominant = trimmed.filter { $0 == first }.count
        return Double(dominant) / Double(trimmed.count) >= 0.9
    }

    private static func collapsedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    private static func boundedUTF8(_ text: String, maxBytes: Int) -> String {
        String(decoding: text.utf8.prefix(maxBytes), as: UTF8.self)
    }
}
