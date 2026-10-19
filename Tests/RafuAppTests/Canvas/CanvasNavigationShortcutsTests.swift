import SwiftUI
import Testing

@testable import RafuApp

/// `CanvasNavigationShortcuts` — the data `CanvasCommands` itself reads to
/// build the shell (⌃⌥1…⌃⌥9) and card-navigation (⌃⌘←↑→↓, ⌃⌘], ⌃⌘[) key
/// equivalents it adds to the "Ensemble" menu. A data-level check here
/// stands in for constructing SwiftUI `Commands` content, which Swift
/// Testing cannot instantiate directly.
@Suite("Canvas navigation shortcuts")
struct CanvasNavigationShortcutsTests {
    /// Shortcuts already live elsewhere in the app that a new one must
    /// never collide with (RafuAppCommands, CanvasCommands' own pre-existing
    /// items, CanvasDiagramMenus, GitInspectorView, WorkspaceCommands).
    private static let existingAppShortcuts: [KeyboardShortcut] = [
        KeyboardShortcut("1", modifiers: [.control, .command]),
        KeyboardShortcut("2", modifiers: [.control, .command]),
        KeyboardShortcut("9", modifiers: .command),
        KeyboardShortcut("9", modifiers: [.command, .option]),
        KeyboardShortcut("0", modifiers: .command),
        KeyboardShortcut("l", modifiers: [.command, .option]),
        KeyboardShortcut("w", modifiers: [.command, .shift]),
        KeyboardShortcut("n", modifiers: [.command, .option]),
        KeyboardShortcut("g", modifiers: [.control, .command]),
        KeyboardShortcut("j", modifiers: [.control, .command]),
        KeyboardShortcut("r", modifiers: [.control, .command]),
        KeyboardShortcut("g", modifiers: [.control]),
        KeyboardShortcut("1", modifiers: [.command, .shift]),
        KeyboardShortcut(.tab, modifiers: [.control]),
        KeyboardShortcut("`", modifiers: [.control]),
        KeyboardShortcut("t", modifiers: .command),
    ]

    @Test("Every shortcut this feature adds is pairwise unique")
    func allShortcutsAreUnique() {
        let shortcuts = CanvasNavigationShortcuts.all
        for i in shortcuts.indices {
            for j in shortcuts.indices where j > i {
                #expect(shortcuts[i] != shortcuts[j], "\(shortcuts[i]) duplicates \(shortcuts[j])")
            }
        }
    }

    @Test("No added shortcut collides with an existing app-wide shortcut")
    func noCollisionWithExistingShortcuts() {
        for shortcut in CanvasNavigationShortcuts.all {
            #expect(!Self.existingAppShortcuts.contains(shortcut))
        }
    }

    @Test("Shell shortcuts are ⌃⌥1 through ⌃⌥9 — never a bare command-digit")
    func shellShortcutsUseControlOption() throws {
        for position in 1...9 {
            let shortcut = try #require(
                CanvasNavigationShortcuts.shellShortcut(forPosition: position))
            #expect(
                shortcut
                    == KeyboardShortcut(
                        KeyEquivalent(Character("\(position)")), modifiers: [.control, .option]))
        }
        #expect(CanvasNavigationShortcuts.shellShortcut(forPosition: 0) == nil)
        #expect(CanvasNavigationShortcuts.shellShortcut(forPosition: 10) == nil)
    }

    @Test("There are exactly nine shell shortcuts and six card-navigation shortcuts")
    func countsMatchTheMenu() {
        #expect(
            (1...9).compactMap(CanvasNavigationShortcuts.shellShortcut(forPosition:)).count == 9)
        #expect(CanvasNavigationShortcuts.cardNavigation.count == 6)
        #expect(CanvasNavigationShortcuts.all.count == 15)
    }
}
