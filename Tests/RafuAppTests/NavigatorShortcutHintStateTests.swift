import AppKit
import Testing

@testable import RafuApp

@Suite("Navigator shortcut hint timing")
struct NavigatorShortcutHintStateTests {
    @Test("Holding Command alone for half a second shows the hints")
    func commandHeldHalfASecondShowsHints() {
        var state = NavigatorShortcutHintState()
        state.flagsChanged(.command, at: 10)
        #expect(state.isArmed)
        #expect(!state.isVisible(at: 10.49))
        #expect(state.isVisible(at: 10.5))
        #expect(state.isVisible(at: 12))
    }

    @Test("Releasing Command early never shows the hints")
    func commandReleasedEarlyNeverShowsHints() {
        var state = NavigatorShortcutHintState()
        state.flagsChanged(.command, at: 10)
        state.flagsChanged([], at: 10.2)
        #expect(!state.isArmed)
        #expect(!state.isVisible(at: 11))
    }

    @Test("A key press before the delay cancels the hints until Command is pressed again")
    func aKeyPressBeforeTheDelayCancelsHints() {
        var state = NavigatorShortcutHintState()
        state.flagsChanged(.command, at: 10)
        state.keyDown(at: 10.2)
        #expect(!state.isVisible(at: 10.6))
        // Command is still held: a repeat flags event must not re-arm it.
        state.flagsChanged(.command, at: 10.7)
        #expect(!state.isVisible(at: 12))
        // Release, then press again: a fresh hold shows them.
        state.flagsChanged([], at: 13)
        state.flagsChanged(.command, at: 14)
        #expect(state.isVisible(at: 14.5))
    }

    @Test("A key press with no Command held does not block the next hold")
    func plainKeyPressDoesNotBlockTheNextHold() {
        var state = NavigatorShortcutHintState()
        state.keyDown(at: 1)
        state.flagsChanged(.command, at: 2)
        #expect(state.isVisible(at: 2.5))
    }

    @Test("Command with another modifier shows nothing")
    func commandWithAnotherModifierShowsNothing() {
        var state = NavigatorShortcutHintState()
        state.flagsChanged([.command, .shift], at: 10)
        #expect(!state.isVisible(at: 11))
        // Releasing Shift while Command stays down is not a new Command press.
        state.flagsChanged(.command, at: 11)
        #expect(!state.isVisible(at: 12))
        // Another modifier after a clean hold cancels it too.
        state.flagsChanged([], at: 13)
        state.flagsChanged(.command, at: 14)
        state.flagsChanged([.command, .option], at: 14.2)
        #expect(!state.isVisible(at: 15))
    }

    @Test("Caps Lock does not count as another modifier")
    func capsLockIsIgnored() {
        var state = NavigatorShortcutHintState()
        state.flagsChanged([.command, .capsLock], at: 10)
        #expect(state.isVisible(at: 10.5))
    }

    @Test("Resigning key hides the hints")
    func resigningKeyHidesHints() {
        var state = NavigatorShortcutHintState()
        state.flagsChanged(.command, at: 10)
        #expect(state.isVisible(at: 11))
        state.windowResignedKey()
        #expect(!state.isVisible(at: 11))
        #expect(!state.isArmed)
    }
}

@Suite("Zen mode Escape policy")
struct ZenModeEscapePolicyTests {
    private func shouldExit(
        zen: Bool = true,
        responder: ZenModeEscapePolicy.Responder = .other,
        sheet: Bool = false,
        switcher: Bool = false,
        board: Bool = false
    ) -> Bool {
        ZenModeEscapePolicy.shouldExit(
            isZenMode: zen, responder: responder, hasAttachedSheet: sheet,
            isEditorTabSwitcherOpen: switcher, isBoardSelected: board)
    }

    @Test("Escape leaves Zen mode only when nothing else could want it")
    func leavesOnlyWhenSafe() {
        #expect(shouldExit())
        #expect(!shouldExit(zen: false))
        #expect(!shouldExit(responder: .textInput))
        #expect(!shouldExit(responder: .terminal))
        #expect(!shouldExit(sheet: true))
        #expect(!shouldExit(switcher: true))
        #expect(!shouldExit(board: true))
    }

    @Test("Only a plain Escape counts")
    func onlyPlainEscape() {
        #expect(ZenModeEscapePolicy.isPlainEscape(keyCode: 53, flags: []))
        #expect(!ZenModeEscapePolicy.isPlainEscape(keyCode: 53, flags: .command))
        #expect(!ZenModeEscapePolicy.isPlainEscape(keyCode: 36, flags: []))
    }

    @MainActor
    @Test("Text views and fields count as text input")
    func classifiesTextResponders() {
        #expect(ZenModeEscapePolicy.classify(NSTextView()) == .textInput)
        #expect(ZenModeEscapePolicy.classify(NSTextField()) == .textInput)
        #expect(ZenModeEscapePolicy.classify(NSView()) == .other)
        #expect(ZenModeEscapePolicy.classify(nil) == .other)
    }
}
