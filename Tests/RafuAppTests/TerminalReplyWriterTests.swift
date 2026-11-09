import Foundation
import Testing

@testable import RafuApp

/// A reply line is the text, then Return as CR in a second write. Agent TUIs in
/// raw mode read LF as "insert a newline"; only CR submits.
@Suite("Terminal reply writer")
@MainActor
struct TerminalReplyWriterTests {
    @MainActor
    private final class Pty {
        var writes: [String] = []
        var running = true
        func write(_ text: String) -> Bool {
            guard running else { return false }
            writes.append(text)
            return true
        }
    }

    /// The delay returns at once, so the second write happens when the test
    /// awaits it.
    @Test("A line is its text, then one CR in a second write, never LF")
    func textThenCarriageReturn() async {
        let pty = Pty()
        let writer = TerminalReplyWriter(write: { pty.write($0) }, wait: { _ in })
        #expect(writer.send("hi"))
        #expect(pty.writes == ["hi"])
        await writer.pendingReturn?.value
        #expect(pty.writes == ["hi", "\r"])
        #expect(!pty.writes.joined().contains("\n"))
        // Nothing more is owed.
        writer.flushReturn()
        #expect(pty.writes == ["hi", "\r"])
    }

    /// The delay never ends on its own, so the order comes only from the
    /// writer: the CR a line owes is written before the next line's text.
    @Test("Two lines in a row never interleave: line 1's CR comes before line 2's text")
    func linesStayInOrder() async {
        let pty = Pty()
        let writer = TerminalReplyWriter(
            write: { pty.write($0) }, wait: { _ in try await Task.sleep(for: .seconds(3_600)) })
        #expect(writer.send("cd /tmp"))
        #expect(writer.send("claude"))
        #expect(pty.writes == ["cd /tmp", "\r", "claude"])
        writer.flushReturn()
        #expect(pty.writes == ["cd /tmp", "\r", "claude", "\r"])
    }

    /// Codex keeps an Enter that follows a fast burst of characters as a
    /// newline for about 120 ms; an explicit paste plus a later CR submits.
    @Test("With bracketed paste on, the text is one explicit paste, then CR")
    func bracketedPasteThenReturn() async {
        let pty = Pty()
        let writer = TerminalReplyWriter(
            write: { pty.write($0) }, isBracketedPaste: { true }, wait: { _ in })
        #expect(writer.send("hi"))
        #expect(writer.owesReturn)
        await writer.pendingReturn?.value
        #expect(pty.writes == ["\u{1B}[200~hi\u{1B}[201~", "\r"])
        #expect(!writer.owesReturn)
    }

    @Test("Return waits well past the Codex paste window")
    func returnDelayClearsPasteWindow() {
        #expect(TerminalReplyWriter.returnDelay >= .milliseconds(200))
    }

    @Test("No process: the text is refused and no CR is owed")
    func refusedWhenNotRunning() async {
        let pty = Pty()
        pty.running = false
        let writer = TerminalReplyWriter(write: { pty.write($0) }, wait: { _ in })
        #expect(!writer.send("hi"))
        #expect(writer.pendingReturn == nil)
        writer.flushReturn()
        #expect(pty.writes.isEmpty)
    }

    @Test("A process that ended does not get the CR its last line owed")
    func discardDropsTheOwedReturn() async {
        let pty = Pty()
        let writer = TerminalReplyWriter(
            write: { pty.write($0) }, wait: { _ in try await Task.sleep(for: .seconds(3_600)) })
        #expect(writer.send("exit"))
        writer.discard()
        writer.flushReturn()
        #expect(pty.writes == ["exit"])
    }
}
