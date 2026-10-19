# SwiftUI on macOS: click latency, hit targets, and click focus

- Applies to: tab strips (file, terminal, Terminal Group, Ensemble, auxiliary
  such as Settings, and diff tabs), list rows with a single and a double
  click action, click-driven editor focus, window-chrome passes that run on
  every tab switch, and the commit graph. Code: `AttachedWorkbenchTab`
  (`Sources/RafuApp/Support/RafuWorkbenchStyles.swift`), `TabClickIntent`,
  `InteractionSignpost`, `EditorClickFocusPolicy`.
- Last verified: Apple Swift 6.4 (swiftlang-6.4.0.34.1), macOS 27.0.1
  (26A434), 2026-10-19. Not measured:
  no before/after latency numbers exist; the fixes below are from code
  analysis and tests. A manual pass on a real window is still required.

## Rule or observed behavior

Users reported that tab clicks felt slow or were ignored. Seven separate
causes were found. Each can recur on a new tab or row type.

1. **Dead hit zones.** The tab's inner `Button` covered only its label. The
   tab's own padding, `minWidth`, and `minHeight` sit outside that button and
   were not clickable (roughly 40 to 50% of the tab area) on file, terminal,
   Terminal Group, Ensemble, auxiliary, and diff tabs. Rule: the complete tab
   shape must be the hit target. `AttachedWorkbenchTab` takes an optional
   `select` closure and applies `.contentShape(.rect)` plus `.onTapGesture` as
   the OUTERMOST modifier. Child buttons (label, close) keep priority in their
   own areas, so Close never also selects. The inner label button stays the
   one accessibility element. New tab kinds must pass `select:`. Close-never-
   selects cannot be proved headlessly; it needs a manual check.
2. **`onTapGesture(count: 2)` next to a single tap.** With both gestures,
   SwiftUI holds every single click until the system double-click interval
   passes. It affected the Terminals panel row and the Terminal Group tab
   rename. Rule: use ONE tap handler and read the click count from the current
   event: `TabClickIntent.resolve(clickCount:eventType:)` fed by
   `NSApp.currentEvent.clickCount` (`TabClickIntent.current()`). A missing
   event, a non-mouse event, and a secondary-button double click all resolve
   to `.select`; only a primary-button count of 2 or more resolves to
   `.selectAndRename`. `WindowDragAttachment.swift` already used the same
   `currentEvent` pattern.
3. **The editor tile livelock kept the main thread busy.** See
   [`editor-gutter-ruler-tiling.md`](editor-gutter-ruler-tiling.md), "Feedback
   loop". A click can only be as fast as the main thread is free.
4. **No editor focus after a file-tab click.** The newly visible editor did
   not become first responder, so typing went nowhere. See "Click focus" below.
5. **`FlatWindowChrome.applyChrome` ran four times per switch** (one
   immediate pass plus three delayed passes) and wrote window properties
   without checking them. Each AppKit setter can invalidate the titlebar or
   window. Rule: `applyChrome` is idempotent. It assigns a window property
   only when it differs from the live value (`isMovable`,
   `.fullSizeContentView`, `titlebarAppearsTransparent`, `titleVisibility`,
   `titlebarSeparatorStyle`, `backgroundColor`; the top safe-area write
   already compared first). A repeated pass does no work. Keep new window
   writes behind the same comparison. See
   [`flat-window-chrome-titlebar-merge.md`](flat-window-chrome-titlebar-merge.md)
   and [`window-chrome-attachment-repair.md`](window-chrome-attachment-repair.md).
6. **Breadcrumb computed in `.task(id:)`** showed the previous path for at
   least one frame after a switch. The segments are now computed
   synchronously from the document (`EditorBreadcrumbPath.segments`).
7. **Commit graph layout ran in `body` on every selection.** `CommitGraphLayoutCache`
   is a reference type held in `@State`. `body` asks it for the layout of the
   current commits. The first call computes synchronously (the first frame
   already has lanes), and it recomputes only when the commit IDs change.
   Mutating the cache during `body` invalidates nothing because nothing
   observes it.

### Click focus

`WorkspaceSession.selectEditorTabFromClick(_:in:)` is the pointer path. It
selects like `selectEditorTab` and, only when the selection actually changed,
sets `EditorDocument.focusEditorOnShow`. The intent is consumed once by the
mount host (`consumeFocusEditorOnShow()`; `EditorMountHostView` waits for
`viewDidMoveToWindow` on a first mount). Navigator reveals, the tab switcher,
and restoration call `selectEditorTab` and never move focus. Any later
selection clears a stale intent.

`EditorClickFocusPolicy.allowsTakingFocus(in:for:)` decides at the moment of
focus. It never takes focus when a sheet is attached, when the editor already
owns it, or when a terminal, a text field (its field editor is a plain
`NSTextView`), or the palette owns it. It does take focus when there is no
responder, the window itself is first responder, another `RafuTextView` owns
it, or the responder is a hidden view (the hidden-view exception).

### Signposts

Subsystem `dev.vatsalsaglani.rafu`, category `Interaction`
(`InteractionSignpost`). Payloads are numbers only (never paths, titles, or
text).

- Event `TabClickQueued`: `inputLatencyMs`, the time from the mouse event's
  timestamp to the moment the app handled it. A large value means the main
  thread was busy before the click was dispatched. Values of 100 ms or more
  also write a `notice` log line.
- Interval `TabSwitch`: from the model change in `selectEditorTab` to the
  completion of the Core Animation transaction that carries the update. A long
  interval means layout or drawing after the switch is slow.

Record with:

```bash
xcrun xctrace record --template 'Time Profiler' --instrument os_signpost \
  --attach RafuLightning --time-limit 30s --output <path>
log stream --info --style compact \
  --predicate 'subsystem == "dev.vatsalsaglani.rafu" AND category == "Interaction"'
```

## Why it matters

Each cause alone makes tabs feel unresponsive, and they stack. The
double-tap delay and dead zones are invisible in a source read: both look
like a normal `Button` plus a gesture. The signposts separate "main thread was
busy" (`TabClickQueued` large) from "the switch is slow" (`TabSwitch` long).

## Reproduction or evidence

- Tests: `Tests/RafuAppTests/TabInteractionResponsivenessTests.swift`
  (click intent resolution, once-only click focus, focus policy, immediate
  breadcrumb segments, commit graph layout cache, signpost latency math).
- Source-contract nuance: `EditorTabAndGroupPresentationTests` searches
  `EditorCanvasView.swift` for the literal `AttachedWorkbenchTab(isSelected:`
  and expects exactly 5. Keep each call on one line starting with that text
  when adding `select:`; do not split the first argument onto its own line.
- Full suites on main (2026-10-19): parallel, 250 + 2522 tests passed;
  `--no-parallel` (CI mode), 250 + 2522 passed.
- Not done (phase 2, needs measurement first): the loaded-editor `ZStack` still
  sits inside the terminal `if`/`else` chain in `EditorCanvasView`, so a
  file-to-terminal switch remounts loaded editors. Moving it out is a
  possible later change; take a `TabSwitch` trace before and after.
- Not provable headlessly: that Close never selects, real hit-zone coverage, and
  that a single click is immediate. Check by hand on a Lightning build:
  click the padding at each end of every tab kind, click Close, double-click
  a Terminal Group tab and a Terminals panel row.

## Verification

```bash
./script/test.sh --filter TabInteractionResponsivenessTests
./script/test.sh --filter EditorTabAndGroupPresentationTests
./script/test.sh --filter FlatWindowChromeTests
./script/build_and_run.sh --verify
```

## Related code, ADRs, and phases

- `Sources/RafuApp/Support/RafuWorkbenchStyles.swift`
  (`AttachedWorkbenchTab`, `AttachedWorkbenchTabSelectTarget`)
- `Sources/RafuApp/Support/TabClickIntent.swift`,
  `Sources/RafuApp/Support/InteractionSignposts.swift`
- `Sources/RafuApp/Views/EditorCanvasView.swift`,
  `Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift`,
  `Sources/RafuApp/Views/FlatWindowChrome.swift`,
  `Sources/RafuApp/Views/GitCommitGraphView.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift`,
  `Sources/RafuApp/Models/EditorDocument.swift`,
  `Sources/RafuApp/Editor/CodeEditorView.swift`
- [`editor-gutter-ruler-tiling.md`](editor-gutter-ruler-tiling.md)
- [`window-scoped-modifier-key-switcher.md`](window-scoped-modifier-key-switcher.md)
- `docs/plans/phases/pre-initial-push-workbench.md`
