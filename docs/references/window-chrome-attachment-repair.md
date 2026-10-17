# Window chrome attachment repair

- **Applies to:** workspace scene creation, `FlatWindowChrome`, and the welcome
  layout in `WorkspaceWindowView`.
- Integration environment: Swift 6.4 (`swiftlang-6.4.0.34.1`), macOS 27.0.1
  (26A434), 2026-10-17. The integrated build and focused regression checks pass.
  Final full-suite results and UI limits are recorded in the repair handoff.
  These checks do not establish a runtime speed gain or release memory budget.

## Rule

Set `.windowStyle(.hiddenTitleBar)` on the workspace `WindowGroup`. This gives
SwiftUI the title presentation at scene creation. Keep the logical navigation
title for the Window menu and other system uses.

The AppKit bridge uses a small `NSView` subclass and `viewDidMoveToWindow` to
bind its coordinator. A lookup queued once from `makeNSView` can run before
the view has a window. If it returns then, the old bridge has no attachment
observer and depends on a later SwiftUI update. The callback removes this
dependency. It also cancels old window observers and pending repairs when
AppKit removes the view. Dismantling clears the weak coordinator reference
before detaching, so an old view cannot bind again.

Keep window mutation on the main actor. The attachment view and coordinator
hold weak references across their ownership boundary. No task or timer is
needed to find the initial window.

## Evidence and limits

The runtime review in
`/tmp/rafu-runtime-review-20261017/evidence/runtime-review.md` records a visible
title and traffic lights in a second, empty window. Opening a folder removed
the title bar. The missing attachment callback is a source-level failure path;
the review did not prove that it was the only cause of the visible defect.

The installed SwiftUI SDK declares `HiddenTitleBarWindowStyle` and
`Scene.windowStyle(_:)` from macOS 11. The AppKit SDK exposes
`NSView.viewDidMoveToWindow`. The repair uses these public entry points before
the existing fallback work.

The three delayed passes and the private backdrop fallback remain. The prior
macOS 26 evidence shows that AppKit can rebuild the full-screen frame after
its notification. Remove these only after first-window, second-window,
inactive-window, sheet, and full-screen checks pass on the supported systems.

## Welcome layout and boundaries

Use the existing `.welcome` canvas route to hide the empty sidebar, utility
rails, and status bar. A top drag area retains pointer movement and hover
reveal of the native controls. `WindowDragHandle` accepts window activation
events so the drag can also start in a background window. No new animation or
translucent surface is added. The open-workspace layout keeps its splitters,
rails, selected-state marks, and theme contrast rules. Its status bar owns the
single top divider.

`EditorCanvasView` still owns the welcome actions and recent-workspace list.
This change does not alter its text, buttons, or cards.

## Top drag area and double-click follow-up

The 2026-10-17 follow-up reserves a quiet 14-point area above the workbench
content outside full screen. It uses the existing surface color and has no
title, divider, toolbar, or controls. File tabs start below it. The existing
top-left control cluster remains above it and owns its input area. The welcome
window keeps its 42-point header. Full screen removes the new workbench inset.

Keep `isMovable = false`. Turning it on also enables the implicit window drag
under file tabs. `WindowDragGesture` remains the explicit move path. A separate
simultaneous two-click gesture passes the current second left mouse-up through
`WindowTitlebarDoubleClickTarget` to the native titlebar container. AppKit owns
the double-click setting and resulting window placement. Do not force Zoom for
all users. The system also supports Fill, Minimize, and No Action; see Apple's
[window guide](https://support.apple.com/en-ie/guide/mac-help/mchlp2469/mac).

SDK inspection on the integration toolchain found `WindowDragGesture` from
macOS 15 and public `NSWindow.performWindowDrag(with:)`, `performZoom(_:)`, and
`performMiniaturize(_:)`. It found no public titlebar-double-click or Fill
action. The bridge therefore resolves the native container through the close
button's ancestors for each click. It does not cache rebuilt frame views or
call a private selector. The container class name is still an AppKit
implementation detail, like the existing backdrop repair. If the container is
absent, the action does nothing. This is a compatibility limit.

The attachment is weak, takes no pointer hits, and belongs to one handle in one
window. Cross-window events, control clicks, full-screen events, and events
while a sheet is attached are rejected. No event monitor, new task, process,
saved preference, file access, or background work is added. The gesture does
not change the editor's first responder.

`WindowDragInteractionRepairTests` checks event ownership after view movement,
input filtering, and the attachment's transparent hit testing. These tests use
a fake native recipient. They do not prove native double-click behavior.
On 2026-10-17, the focused interaction tests and canonical Lightning launch
passed on Swift 6.4 / macOS 27.0.1. A top-area double click visibly enlarged
the window, and a second restored its size. This confirms event forwarding
under the current system preference only. The top drag action was exercised;
the app-only screenshot did not expose screen position for measurement.
Split creation and second-window creation preserved editor state. Full-screen
entry and exit were checked. Other double-click preferences, inactive-window dragging,
and tab reorder remain manual checks.

## Verification

New automated coverage is in `WindowChromeAttachmentRepairTests`:

- Attach after a main-queue boundary with no intervening view update.
- Apply the latest configuration and topology on attachment.
- Cancel old repairs on removal and target only the new window on attachment.
- Prevent a dismantled view from binding again.

Run these commands in the integration checkout under its build slot:

```sh
./script/test.sh --filter WindowChromeAttachmentRepairTests
./script/test.sh --filter WindowDragInteractionRepairTests
./script/test.sh --filter FlatWindowChromeTests
./script/test.sh --filter WindowChromeTopologyLifecycleTests
./script/test.sh --filter WorkbenchDeckPresentationTests
```

The coordinator owns full format, build, parallel and serial test gates, and
the canonical Lightning bundle check. The coordinator checked two windows,
keyboard Find and Settings, folder opening, and full-screen entry/exit. Remaining
manual checks include: first and second empty windows, opening
a folder, Settings, keyboard/menu access, drag movement from inactive windows,
native controls, sheets, full-screen entry and exit, light/dark themes, Increase
Contrast, and Reduce Motion. Automated attachment tests do not prove those UI
results.

## Related

- [Titlebar merge rules](flat-window-chrome-titlebar-merge.md)
- [ADR 0002](../decisions/0002-native-workbench-navigation.md)
- [ADR 0012](../decisions/0012-flat-workbench-chrome.md)
- [Workbench phase](../plans/phases/pre-initial-push-workbench.md)
- Coordinator phase: `docs/plans/phases/editor-performance-repair.md`

This note is listed in the reference index.
