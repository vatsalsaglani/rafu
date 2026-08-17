# Cmd+W window close resolution order and per-window targeting

- **Applies to:** `WorkspaceSession.requestCloseActiveTab()`, per-window Cmd+W routing, empty-window quit confirmation, `WorkspaceWindowRegistry` tracking
- **Last verified:** Swift 6.2, macOS 26, 2026-08-17

## Rule or observed behavior

Cmd+W close resolution follows a prioritized order that routes first through the focused editor group, then through any open Git diff, and finally resolves an empty window distinctly from a true app quit:

1. **Focused editor group's selected tab:**
   - File tab: routes to `EditorDocument.requestClose()`, preserving the existing dirty-save-confirmation UX
   - Terminal tab: routes to `requestCloseTerminalTab()`, terminating the shell per ADR 0014 (terminal sessions never park when explicitly closed from the tab ✕ or Cmd+W)
   - Terminal Group: closes the focused pane when siblings remain. A live
     process gets a pane-specific confirmation. The last pane uses the
     complete group-close path and its group-level confirmation. **Close and
     Don’t Ask Again** stores one app-scoped Boolean that skips later running
     pane warnings. It does not skip complete group-close confirmation.
   - Restorable tab (`.restorable`, only for `.file` resource type): routes to the generic `editorLayout.closeTab()` path

2. **Open Git diff (editor-hosted):** if present and the group has no tabs, closes the diff view

3. **Empty editor window** (no tabs, no open diff):
   - **Close this window only** if other workspace windows remain open
   - **Trigger the existing app-quit confirmation UX** ("⌘Q or click the red close button to quit") if this is the last window

**SwiftUI `dismissWindow` limitation:** SwiftUI's `.dismissWindow` API closes ALL windows of a `WindowGroup` with the matching ID (global behavior, not per-window). Per-window Cmd+W must route through `WorkspaceWindowRegistry`'s tracked `NSWindow` references and call `NSWindow.performClose(nil)` directly.

## Restorable tab safety

`.restorable` tabs (empty editor group placeholders from a restored session that haven't been opened yet) back no live process and cannot be dirty (`EditorTabResource.isRestorable` is true only when the underlying resource is `.file` and restoration state exists). The generic close path is safe for them.

## Why it matters

Cmd+W is the universal close-focused-thing shortcut on macOS; its behavior must be consistent, predictable, and distinct from Cmd+Q. Users expect Cmd+W to close one focused item, not the entire application. Inside a Terminal Group, the focused pane is that item while siblings remain. The resolution order ensures that closing behavior cascades sensibly from pane to tab to window. A running pane stops after confirmation unless the user explicitly saved the pane-only suppression preference. A complete group still requires its own warning.

## Testing gotcha: AppKit window-close crashes

**High-value finding, reusable:** driving a real `NSWindow.performClose(nil)` inside a test crashes intermittently with SIGSEGV under swift-testing's PARALLEL execution in this environment. The mitigation used:

1. Extract the pure decision logic (`resolveEmptyWindowCloseAction(hasOtherWorkspaceWindows:quitWithoutEmptyWindowConfirmation:)`) into a testable, side-effect-free function
2. Unit-test that function directly
3. Test the registry's window count via a test that never calls `performClose`

**Anyone adding AppKit window-closing tests in the future must know this constraint.** The tests that DO call `performClose` are currently excluded from the swift-testing parallel execution; verify that any new window-close tests follow the same pattern or run serially.

## Reproduction or evidence

- Unit tests for the decision logic: `resolveEmptyWindowCloseAction(hasOtherWorkspaceWindows:quitWithoutEmptyWindowConfirmation:)` tested in isolation with various input combinations
- Window-registry count tests: verify that `liveWorkspaceWindowCount()` returns the correct tally after windows are added and removed (without calling `performClose`)
- Integration tests for each tab type and Terminal Group pane/group close route against a dummy session

## Verification

```bash
swift build
swift test --filter WorkspaceCloseAction
swift test --filter WorkspaceWindowRegistry
swift test
./script/format.sh --lint
./script/build_and_run.sh --verify
```

`./script/test.sh`: 2,151 tests passed in parallel mode. `./script/test.sh
--no-parallel`: 2,151 tests passed in sequential CI mode. Format lint and build
passed. `./script/build_and_run.sh --verify` launched Rafu Lightning. A live
two-pane check showed the info-color dotted focus border inside the solid group
outline and showed **Close and Don’t Ask Again** only on the pane warning.

## Related code, ADRs, and phases

- `Sources/RafuApp/Models/WorkspaceSession.swift` — `requestCloseActiveTab()`, `closeFocusedTabIfPresent()`, `EmptyWindowCloseAction`, `resolveEmptyWindowCloseAction(…)`
- `Sources/RafuApp/Support/WorkspaceWindowRegistry.swift` — `liveWorkspaceWindowCount()`, `closeWindow(for:)`, per-window tracking
- `Tests/RafuAppTests/WorkspaceCloseActionTests.swift` — focused tests for decision logic and registry counts
- `Tests/RafuAppTests/TerminalGroupCloseIntegrationTests.swift` — focused-pane and last-pane Command-W behavior
- `Sources/RafuApp/Terminal/TerminalPaneClosePreferenceStore.swift` — the
  app-scoped, nonsecret pane-warning preference
- [ADR 0004](0004-embedded-terminal.md) — terminal lifecycle (sessions never auto-park on close)
- [ADR 0014](0014-terminal-as-editor-tab.md) — terminal sessions as editor tabs, explicit hide vs. close semantics
- [`swiftui-appkit-boundary.md`](swiftui-appkit-boundary.md) — window and responder management
- `docs/plans/phases/pre-initial-push-workbench.md` — acceptance item #14 (Cmd+W behavior)
