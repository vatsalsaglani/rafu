import AppKit
import SwiftTerm
import Testing

@testable import RafuApp

@Suite("Terminal modified Return", .serialized)
@MainActor
struct TerminalNewlineTests {
    @Test(
        "Legacy modified Return sends one LF instead of submitting CR",
        arguments: [NSEvent.ModifierFlags.shift, .control, [.shift, .control]])
    func modifiedReturn(modifiers: NSEvent.ModifierFlags) throws {
        let view = RafuTerminalView(frame: .zero)
        let capture = InputCapture()
        view.terminalDelegate = capture
        for keyCode: UInt16 in [36, 76] {
            capture.bytes = []
            #expect(view.handleLegacyNewline(try event(keyCode: keyCode, modifiers: modifiers)))
            #expect(capture.bytes == [0x0A])
        }
        view.terminalDelegate = nil
    }

    @Test("Plain Return, Option, Command, other keys and IME stay with SwiftTerm")
    func excludedInput() throws {
        for modifiers: NSEvent.ModifierFlags in [
            [], .option, .command, [.shift, .command], [.control, .option],
        ] {
            #expect(
                !TerminalNewlinePolicy.usesLegacyLineFeed(
                    event: try event(modifiers: modifiers), hasMarkedText: false,
                    hasKeyboardProtocol: false))
        }
        #expect(
            !TerminalNewlinePolicy.usesLegacyLineFeed(
                event: try event(keyCode: 0, modifiers: .shift), hasMarkedText: false,
                hasKeyboardProtocol: false))
        #expect(
            !TerminalNewlinePolicy.usesLegacyLineFeed(
                event: try event(modifiers: .shift), hasMarkedText: true, hasKeyboardProtocol: false
            ))
        #expect(
            !TerminalNewlinePolicy.usesLegacyLineFeed(
                event: try event(modifiers: .shift, type: .keyUp), hasMarkedText: false,
                hasKeyboardProtocol: false))
        #expect(
            TerminalNewlinePolicy.usesLegacyLineFeed(
                event: try event(modifiers: [.shift, .capsLock, .numericPad]),
                hasMarkedText: false, hasKeyboardProtocol: false))
        let view = RafuTerminalView(frame: .zero)
        let capture = InputCapture()
        view.terminalDelegate = capture
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(capture.bytes == [0x0D])
        view.terminalDelegate = nil
    }

    @Test("Negotiated Kitty keys retain modifiers and reset restores legacy newlines")
    func negotiatedProtocol() throws {
        let view = RafuTerminalView(frame: .zero)
        let capture = InputCapture()
        view.terminalDelegate = capture
        view.feed(text: "\u{1b}[>1u")
        #expect(!view.getTerminal().keyboardEnhancementFlags.isEmpty)
        for (modifiers, expected): (NSEvent.ModifierFlags, String) in [
            (.shift, "\u{1b}[13;2u"), (.control, "\u{1b}[13;5u"),
        ] {
            let key = try event(modifiers: modifiers)
            capture.bytes = []
            #expect(!view.handleLegacyNewline(key))
            view.keyDown(with: key)
            #expect(capture.bytes == Array(expected.utf8))
        }
        view.feed(text: "\u{1b}[<u")
        capture.bytes = []
        #expect(view.handleLegacyNewline(try event(modifiers: .shift)))
        #expect(capture.bytes == [0x0A])
        view.terminalDelegate = nil
    }

    @Test("One monitor routes only to the visible terminal in the event window")
    func windowAndLifecycle() throws {
        _ = NSApplication.shared
        let initialCount = TerminalNewlineMonitor.registrationCount
        let first = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        let second = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        let a = RafuTerminalView(frame: first.contentView!.bounds)
        let b = RafuTerminalView(frame: second.contentView!.bounds)
        let captureA = InputCapture()
        let captureB = InputCapture()
        a.terminalDelegate = captureA
        b.terminalDelegate = captureB
        first.contentView?.addSubview(a)
        second.contentView?.addSubview(b)
        defer {
            a.removeFromSuperview()
            b.removeFromSuperview()
            a.terminalDelegate = nil
            b.terminalDelegate = nil
            first.close()
            second.close()
        }
        #expect(TerminalNewlineMonitor.registrationCount == initialCount + 2)
        #expect(first.makeFirstResponder(a))
        #expect(second.makeFirstResponder(b))
        let keyA = try event(modifiers: .shift, windowNumber: first.windowNumber)
        #expect(TerminalNewlineMonitor.handle(keyA) == nil)
        #expect(captureA.bytes == [0x0A])
        #expect(captureB.bytes.isEmpty)
        a.isHidden = true
        #expect(TerminalNewlineMonitor.handle(keyA) === keyA)
        a.isHidden = false
        let field = NSTextView(frame: .zero)
        first.contentView?.addSubview(field)
        #expect(first.makeFirstResponder(field))
        #expect(TerminalNewlineMonitor.handle(keyA) === keyA)
        a.removeFromSuperview()
        #expect(TerminalNewlineMonitor.registrationCount == initialCount + 1)
        b.removeFromSuperview()
        #expect(TerminalNewlineMonitor.registrationCount == initialCount)
    }

    private func event(
        keyCode: UInt16 = 36, modifiers: NSEvent.ModifierFlags,
        type: NSEvent.EventType = .keyDown, windowNumber: Int = 0
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: keyCode))
    }
}

@MainActor
private final class InputCapture: TerminalViewDelegate {
    var bytes: [UInt8] = []
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { bytes.append(contentsOf: data) }
    }
    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
