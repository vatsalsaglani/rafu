import Foundation

/// Types one line into a terminal and submits it with Return.
///
/// Return is `"\r"` (CR), never `"\n"` (LF). Agent TUIs run the tty in raw
/// mode: Claude Code (ink) and Codex (crossterm) read LF as Ctrl-J, which
/// inserts a newline in their prompt, and only CR submits. A shell's line
/// editor accepts both, which is why LF looked right in a plain shell.
///
/// The CR goes in a second write, `returnDelay` after the text. Some TUIs
/// treat text and CR that arrive in one read as a paste and keep the CR as
/// text. The CR a line still owes is written before the next line's text,
/// so lines never interleave, whoever calls `send` and however fast.
/// See `docs/references/ensemble-agent-terminal-tools.md`.
@MainActor
final class TerminalReplyWriter {
    static let returnDelay: Duration = .milliseconds(50)
    static let returnKey = "\r"

    typealias Wait = @MainActor (Duration) async throws -> Void

    /// Writes to the live pty. False when no process runs.
    private let write: @MainActor (String) -> Bool
    private let wait: Wait
    private var owesReturn = false
    /// The delayed Return. A test awaits it to see the second write.
    private(set) var pendingReturn: Task<Void, Never>?

    init(
        write: @escaping @MainActor (String) -> Bool,
        wait: @escaping Wait = { try await Task.sleep(for: $0) }
    ) {
        self.write = write
        self.wait = wait
    }

    /// Writes `text` now and Return after `returnDelay`. False when the text
    /// could not be written.
    func send(_ text: String) -> Bool {
        flushReturn()
        guard write(text) else { return false }
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
