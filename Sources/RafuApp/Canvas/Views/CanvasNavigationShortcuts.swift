import SwiftUI

/// The keyboard shortcuts `CanvasCommands` adds to the "Ensemble" menu,
/// exposed as plain data so a test can check them for collisions without
/// building SwiftUI `Commands` content. `CanvasCommands` itself calls these
/// same functions, so the test exercises the real wiring, not a parallel
/// copy that could drift.
nonisolated enum CanvasNavigationShortcuts {
    /// ⌃⌥1…⌃⌥9 — one per discovered-shell catalog position (1 = the default
    /// shell). `nil` outside 1...9: a menu key equivalent is a single
    /// character, so there is nothing to assign past the ninth shell.
    static func shellShortcut(forPosition position: Int) -> KeyboardShortcut? {
        guard (1...9).contains(position) else { return nil }
        return KeyboardShortcut(
            KeyEquivalent(Character("\(position)")), modifiers: [.control, .option])
    }

    /// ⌃⌘←↑→↓ (spatial focus) and ⌃⌘] / ⌃⌘[ (reading-order focus), in the
    /// order `CanvasCommands.cardNavigationItems` declares its buttons.
    static let cardNavigation: [KeyboardShortcut] = [
        KeyboardShortcut(.leftArrow, modifiers: [.control, .command]),
        KeyboardShortcut(.rightArrow, modifiers: [.control, .command]),
        KeyboardShortcut(.upArrow, modifiers: [.control, .command]),
        KeyboardShortcut(.downArrow, modifiers: [.control, .command]),
        KeyboardShortcut("]", modifiers: [.control, .command]),
        KeyboardShortcut("[", modifiers: [.control, .command]),
    ]

    /// Every shortcut this feature adds: the (at most) nine shell shortcuts,
    /// then the six navigation shortcuts.
    static var all: [KeyboardShortcut] {
        (1...9).compactMap(shellShortcut(forPosition:)) + cardNavigation
    }
}
