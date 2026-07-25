# Window-scoped modifier-key switchers

- **Applies to:** Ctrl-Tab-style overlays, SwiftUI scene commands, AppKit first-responder keyboard routing, and per-window `NSEvent` monitors
- **Last verified:** Swift 6.3.3, Xcode 26.6, macOS 26.5.2 on 2026-07-25

## Rule or observed behavior

A hold-and-release keyboard switcher in a mixed SwiftUI/AppKit window needs two
deliberately separate routing paths:

1. Register Ctrl-Tab and Ctrl-Shift-Tab as SwiftUI menu key equivalents backed
   by the focused `WorkspaceSession`. AppKit resolves menu key equivalents
   before an `NSTextView` or SwiftTerm first responder consumes the event, so
   the shortcut remains window-contextual without adding interception code to
   either editor implementation.
2. Keep the switcher's highlighted destination as small, window-owned
   observable state. Do not select editor tabs while browsing; commit once on
   Control release so Left/Right key repeat does not churn document
   hibernation, terminal attention clearing, or workspace persistence.
3. Use a zero-sized `NSViewRepresentable` only for the capability SwiftUI does
   not expose: a window-scoped modifier-release event. Its local event monitor
   consumes Left, Right, Escape, and Return only while the switcher is visible.
   Ctrl-Tab itself continues to the SwiftUI command.
4. An `NSEvent` local monitor is application-wide even when installed by a
   window view. Filter every event through the attached window's identity and
   `isKeyWindow`, cancel on `didResignKey`, and remove both the monitor and
   observer in `dismantleNSView`.
5. A menu item chosen with the pointer has no later Control-release event.
   Check `NSEvent.modifierFlags` in the command action and commit immediately
   when Control is not held, or the overlay remains stranded.

Under Swift 6 strict concurrency, the opaque local-monitor token is `Any` and
not `Sendable`. A `@MainActor` coordinator therefore needs `isolated deinit` to
remove that token; an ordinary nonisolated deinitializer cannot read it.
Avoid `@unchecked Sendable` or `nonisolated(unsafe)` for this lifecycle cleanup.

## Why it matters

Registering all keys globally would steal ordinary arrow/Return behavior from
the editor, terminal, command palette, and settings. Handling everything in the
first responder would duplicate the feature across TextKit and SwiftTerm.
Splitting the menu-equivalent start from a minimal release/navigation bridge
keeps the source of truth in SwiftUI, preserves normal responder behavior while
the overlay is closed, and prevents one workspace window from driving another.

## Reproduction or evidence

- With at least two destinations, Ctrl-Tab constructs a preview selection
  without changing the focused editor group.
- Repeated Ctrl-Tab and Left/Right wrap through the same candidate list.
- Control release or Return selects once; Escape leaves the prior tab selected.
- Presented terminal tabs and parked sessions share terminal-session identity,
  so a terminal appears once and a parked session is revealed on commit.
- Compiling the monitor cleanup with an ordinary `deinit` fails because
  `Any?` is non-Sendable; `isolated deinit` compiles without weakening
  concurrency checking.

## Verification

```bash
swift test --filter EditorTabSwitcher
swift test
./script/format.sh --lint
./script/build_and_run.sh --verify
```

The focused suite covers wraparound, the one-destination no-op, deduplication,
parked-terminal reveal, cancel, and cross-split focus. Real keyboard use with a
file editor and SwiftTerm first responder remains part of the user's hands-on
GUI acceptance pass.

## Related code, ADRs, and phases

- `Sources/RafuApp/App/RafuAppCommands.swift`
- `Sources/RafuApp/Editor/EditorTabSwitcher.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift`
- `Sources/RafuApp/Views/EditorTabSwitcherView.swift`
- `Sources/RafuApp/Views/WorkspaceWindowView.swift`
- `Tests/RafuAppTests/EditorTabSwitcherTests.swift`
- [ADR 0014](../decisions/0014-terminal-as-editor-tab.md)
- [`swiftui-appkit-boundary.md`](swiftui-appkit-boundary.md)
- [`pre-initial-push-workbench.md`](../plans/phases/pre-initial-push-workbench.md)
