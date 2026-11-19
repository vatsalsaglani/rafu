# Ensemble terminal focus across a hidden window

- Applies to: Ensemble terminal cards when the board's window is hidden and
  shown again (another Space, an app that covers the window, the screen lock).
  Code: `CanvasBoardResources.pause()` / `windowBecameAvailable()` and
  `CanvasContentFocusRestore` in
  `Sources/RafuApp/Canvas/Integration/CanvasBoardResources.swift`.
- Last verified: 2026-11-19, Swift 6.4.2, macOS 27.2.1 (26B8132), by tests
  only. No GUI check of the running app was done.

## Rule

When the window is hidden, `pause()` remembers the terminal card that had the
keys (`board.contentFocusToRestore`). When the window shows again,
`windowBecameAvailable()` calls `board.focus(card)`. The card then takes the
keys back by the same path as a click: `CanvasTerminalCard`'s
`onChange(of: active)` claims the lease, reveals and focuses the pane, and
`TerminalHostView` makes the terminal the first responder when it mounts.

While a restore is pending, the board's own keys stay off:
`CanvasContentFocusRestore.contentHoldsKeys` gates both the tool-letter monitor
(`CanvasToolKeyHandler.keysActive`) and the board's `onKeyPress` handlers
(`boardTakesKeys`). Leaving content or hiding the board
(`leaveInteractiveContent`) ends the pending restore, so the board can never
lose its keys for good.

Only terminal cards are restored. Notes and web cards are not.

## Why it matters (root cause)

AppKit keeps a window's first responder across app and Space switches. The
loss came from Rafu: `CanvasScrollBridge` calls `pause()` when the window's
occlusion state loses `.visible`. `pause()` → `stopAll()` releases every
terminal lease, parks the groups (the terminal view leaves the window, so it
stops being first responder), and `leaveInteractiveContent()` sets
`board.contentIsActive = false`. The board view's
`onChange(of: board.contentIsActive)` then gave the board keyboard focus.
`windowBecameAvailable()` only set a flag. On return the board had the keys,
`keysActive` was true, and typed letters (V, R, T, N, …) ran board tools
instead of reaching the shell.

A plain app switch that does not hide the window does not cause this: no
`pause()` runs and the terminal stays first responder.

## Reproduction or evidence

`CanvasTerminalFocusRestoreTests`: add a terminal card (it gets the keys),
`pause()` twice, check the board letters are off, `windowBecameAvailable()`,
check the card has the keys again. Also: board focus is unchanged when the
board had the keys, and `stopAll()` or removing the card ends the restore.

## Verification

```bash
swift test --filter CanvasTerminalFocusRestoreTests
swift test --filter CanvasTerminalLeaseTests
```

Manual: type in an Ensemble terminal, switch to another Space (or a
full-screen app) and back, type letters. They must reach the shell, not pick a
tool or add a node. Repeat with the screen lock.

## Related code, ADRs, and phases

- `Sources/RafuApp/Canvas/Adapters/CanvasScrollBridge.swift` (occlusion
  observer), `Sources/RafuApp/Canvas/Adapters/CanvasTerminalCard.swift`,
  `Sources/RafuApp/Terminal/EditorTerminalTabContent.swift`
  (`TerminalHostView` focus request on mount),
  `Sources/RafuApp/Canvas/Whiteboard/CanvasToolPalette.swift`
  (`CanvasToolKeyMonitor`).
- [`canvas-interaction.md`](canvas-interaction.md) (board-key gating),
  [`ensemble-agent-terminal-tools.md`](ensemble-agent-terminal-tools.md)
  (presentation lease).
