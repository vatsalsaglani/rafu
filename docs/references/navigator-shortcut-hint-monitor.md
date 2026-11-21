# Navigator shortcut hint monitor and the Zen Escape rule

## Applies to

`NavigatorShortcutHintMonitor`, `NavigatorShortcutHintState` and `ZenModeEscapePolicy` in
`Sources/RafuApp/Views/NavigatorShortcutHints.swift`, and their use in `WorkspaceWindowView`.

## Last verified

- Apple Swift 6.4, macOS 27, arm64. Unit tests only (`NavigatorShortcutHintStateTests`). The live key behaviour
  is a pending GUI check (see the decision record about navigator number keys, ADR 0043).

## Rule

1. **One local monitor per window, key window only.** The monitor is
   `NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown])`. It acts only while its host window
   `isKeyWindow` and the event has no window or that window. A global monitor never fires while Rafu is active, so
   it is not used.
2. **Return every event unchanged.** The monitor reads. The one exception is a plain Escape that the Zen handler
   used: that event is consumed (returns `nil`). A monitor that consumed other keys could break a click, a menu
   key equivalent or text entry anywhere in the app.
3. **Install and remove with the window.** `NavigatorHintWindowReader` gives the monitor its window when AppKit
   attaches the view (`viewDidMoveToWindow`) and `nil` when it leaves (`dismantleNSView`). The monitor removes the
   event monitor and the resign-key observer on `remove()` and in `deinit`.
4. **0.5 s delay, one cancellable task.** The badges show after Command is held alone for 0.5 s. `NavigatorShortcutHintState`
   is a pure value type with the time passed in, so tests use fixed times and no sleeps. The monitor starts one
   `Task.sleep` when the state arms and cancels it on any change. A key press, another modifier, or the window
   resigning key hides the badges until Command is released and pressed again. Caps Lock is ignored.
5. **Escape leaves Zen mode only when safe.** `ZenModeEscapePolicy.shouldExit` is false when the first responder is
   an `NSText` or `NSTextField` (the editor, every field editor, the command palette), a SwiftTerm `TerminalView`,
   when a sheet is attached, when the tab switcher is open, or when an Ensemble board is the selected tab. Escape
   then reaches its owner unchanged.

## Why it matters

A hold-to-reveal hint that flashes on every Command S is noise. A monitor that returns `nil` for a key it does not own
breaks other features silently. Escape is used by text fields, terminals, the command palette and the Ensemble board;
Zen mode must not take it from them.

## Reproduction and evidence

- `swift test --filter NavigatorShortcutHintStateTests` and `--filter ZenModeEscapePolicyTests`.
- Manual: hold Command for 0.5 s in the key window (badges), press Command S quickly (no badges), enter Zen mode and
  press Escape in the editor, a terminal and a text field (no exit), then on the empty deck (exit).

## Verification commands

`swift test --filter NavigatorShortcutHintStateTests`, `swift test --filter ZenModeEscapePolicyTests`,
`swift test --filter WorkspaceSessionZenModeTests`.

## Related

ADR 0043; `Sources/RafuApp/Views/CommandPaletteKeyMonitor.swift` (the same "local monitor, own window only" pattern);
`Sources/RafuApp/Views/EditorTabSwitcherView.swift` (`EditorTabSwitcherEventBridge`).
