import Foundation

/// Types one line into a terminal and submits it with Return.
///
/// Return is `"\r"` (CR), never `"\n"` (LF). Agent TUIs run the tty in raw
/// mode: Claude Code (ink) and Codex (crossterm) read LF as Ctrl-J, which
/// inserts a newline in their prompt, and only CR submits. A shell's line
/// editor accepts both, which is why LF looked right in a plain shell.
///
/// The CR goes in a second write, `returnDelay` after the text. TUIs that
/// detect a paste by timing keep an Enter that follows a fast burst of
/// characters as a newline: Codex does this for about 120 ms after the burst,
/// so 50 ms submitted some lines and not others (2026-11-09). When the
/// program turned bracketed-paste mode on (Claude Code, Codex and zsh do),
/// the text goes as an explicit paste (`ESC[200~ … ESC[201~`), so the CR is
/// a key press, not part of a paste. The CR a line still owes is written
/// before the next line's text, so lines never interleave, whoever calls
/// `send` and however fast; the Ensemble drain also waits for it.
/// See `docs/references/ensemble-agent-terminal-tools.md`.
@MainActor
final class TerminalReplyWriter {
    static let returnDelay: Duration = .milliseconds(250)
    static let pasteStart = "\u{1B}[200~"
    static let pasteEnd = "\u{1B}[201~"
    static let returnKey = "\r"

    typealias Wait = @MainActor (Duration) async throws -> Void

    /// Writes to the live pty. False when no process runs.
    private let write: @MainActor (String) -> Bool
    private let wait: Wait
    /// True while the program has bracketed-paste mode on.
    private let isBracketedPaste: @MainActor () -> Bool
    /// True between a line's text and its Return.
    private(set) var owesReturn = false
    /// The delayed Return. A test awaits it to see the second write.
    private(set) var pendingReturn: Task<Void, Never>?

    init(
        write: @escaping @MainActor (String) -> Bool,
        isBracketedPaste: @escaping @MainActor () -> Bool = { false },
        wait: @escaping Wait = { try await Task.sleep(for: $0) }
    ) {
        self.write = write
        self.isBracketedPaste = isBracketedPaste
        self.wait = wait
    }

    /// Writes `text` now (as a bracketed paste when the program asked for
    /// one) and Return after `returnDelay`. False when the text could not be
    /// written. Callers already refuse control characters in `text`, so it
    /// cannot end the paste early.
    func send(_ text: String) -> Bool {
        flushReturn()
        let payload = isBracketedPaste() ? Self.pasteStart + text + Self.pasteEnd : text
        guard write(payload) else { return false }
        owesReturn = true
        pendingReturn = Task { [weak self] in
            do { try await self?.wait(Self.returnDelay) } catch { return }
            self?.flushReturn()
        }
        return true
    }

    /// Writes the Return a line still owes, at once.
    func flushReturn() {
        guard owesReturn else { return }
        owesReturn = false
        pendingReturn?.cancel()
        pendingReturn = nil
        _ = write(Self.returnKey)
    }

    /// The process ended or restarted: a Return still owed is not written to
    /// whatever runs next.
    func discard() {
        owesReturn = false
        pendingReturn?.cancel()
        pendingReturn = nil
    }
}
