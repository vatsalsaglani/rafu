# Generated-view card and its saved state

- Applies to: `Sources/RafuApp/Canvas/GeneratedView/**` (card, model, state
  persistence, budget, host actions, theme, export), `GeneratedViewModels`, and
  the `generatedView` card content in the board file
  ([ADR 0036](../decisions/0036-generated-views-on-the-ensemble-board.md)).
- Last verified: Swift 6.4.2, macOS 27, 2026-11-08. Rules about the stream undo
  collapse and the MDX theme describe the fix round on branch
  `fix/voice-mic-allow`, which was not merged when this note was written. Run
  results (test counts) and the memory numbers were not part of the handoff; see
  the open checks at the end.

## Rule or observed behavior

### Model lifecycle and registry

- `GeneratedViewModels.shared` holds one `GeneratedViewCardModel` per card per
  board window. The board drops a card's view when it scrolls out of sight, so
  the model must outlive the view: it keeps the `StateStore` (and a draft that is
  never saved) until the card or the board goes away. `prune()` stops the models
  of closed boards and removed cards. The registry holds boards weakly.
- Only the card's `RenderModel` (the rendered tree) is released off-screen. The
  decoded spec and the store stay.
- The model installs `board.generatedViewStateSnapshots[cardID]`. The board
  pulls it at save time and folds the state into the document with no undo step.
- State is never an undo step. Create and update are one undo step each. A
  document state that becomes `nil` (Reset View) resets the live store; one that
  comes back from `nil` (Undo of Reset View) is applied. Any other document state
  change with the same spec (the model's own save, or an undo of an unrelated
  edit) leaves the live state alone; the model remembers the last 8 states it
  wrote to tell its own save from an outside change.

### Debounce and snapshot

- Each store snapshot restarts a 500 ms debounce (`Task.sleep`). When it fires,
  the model computes the saved form and marks the board dirty. Quit and
  `stateForSave` also flush a pending value.
- Snapshot filter order in `GeneratedViewStatePersistence.snapshot`:
  1. keys that start with `_`, at any depth;
  2. paths bound by a secret prop (`secretProps`; `$bindState` and `$bindItem`
     rows; a nested repeat drops the whole outermost repeated array);
  3. `transientPaths` (empty by policy now);
  4. scalar values over 4 KiB;
  5. the cap: if the canonical text is over the cap, the newest changed paths go
     back to their seed value first, one by one, until it fits. If it still does
     not fit, nothing is saved.
  Secrets are removed before the cap, so a secret never takes space from another
  value. The journal holds paths and counts only, never values, at most 20 lines
  of 160 characters. The card shows "Some state was not saved" when a cap fired.
- `specVersion` is the SHA-256 (lowercase hex, 64 characters) of the canonical
  spec (`.sortedKeys`, `.withoutEscapingSlashes`) without its `state` key. The
  saved state is applied only when `specVersion` and `catalogVersion`
  (`RafuCatalog.version`) both match. Otherwise the store takes the spec's own
  `state` seed and the header says "View reset: the view changed" or "View reset:
  Rafu was updated".

### Reset View

Header menu, context menu, ⌥⌘R (focused card, else the single selected card, when
it is a view) and `view_update` with `reset`. The state shown now is first
written into the document with no undo step, then the document state is set to
`nil` in one undo step, so Undo brings the shown state back.

### Stream undo collapse (voice)

`GeneratedViewStreamSession.finish` collapses the skeleton step and the final
write into one undo step only when: `board.canUndo`, no card content is active,
`board.changeStamp` equals the stamp taken just after the skeleton step, and
`CanvasAgentUndoGate` still allows it. The stamp check is the fix-round
correction: the gate compares only cards and connections, but a rename or a
consent change is also an undo step. If any check fails, the final spec is an
ordinary update of the skeleton card (two honest undo steps). The same check
decides how a failed or cancelled stream removes its skeleton. The gate still
cannot see a change that touches neither cards nor connections, such as a
provenance notice; that weakness predates wave 3.

### Budget maths

`GeneratedViewBudget`: all specs and saved states on one board share 1 MiB,
counted as the bytes they take in the saved file (`storedBytes`: a quote,
backslash, slash or control character counts as 2 bytes, and a low control
character as 6, because a spec is stored as one JSON string and `JSONEncoder`
escapes `/`). One spec is at most 256 KiB, one board at most 50 views, one saved
state at most 64 KiB or what is left of the 1 MiB, whichever is smaller. A create
or update over budget is refused with a reason; a state over budget is saved
smaller or not at all.

### Theme

`JSONRenderTheme.rafu(palette)` maps palette roles (card and elevated
background, three text roles, `borderSubtle`, accent, on-accent, success,
warning, error, info, focus ring) and the `RafuMetrics` radii onto
`JSONRenderTheme.native`; type, spacing, elevation, motion and chart tokens stay
the package's. A role that fails the package contrast rules steps to a stronger
role of the same palette, in at most three passes: muted text to secondary to
primary text; on-accent to black or white by luminance; accent to primary text.
`GeneratedViewThemeCache` (main actor) stores one mapped theme per Rafu theme and
logs a fallback once per theme with role names only. The card, the PNG export and
the MDX preview all take the theme from this cache, so the contrast report is not
measured in `body` on each render.

### Export

The static export card draws a rasterised snapshot made through
`GeneratedViewExport`, with the theme from the cache.

### Memory fixture

```bash
RAFU_VIEW_FIXTURE_OUT=/tmp/twenty-views.rafuensemble swift test --filter GeneratedViewMemoryFixtureTests
```

writes a board with 20 view cards to open in Rafu Lightning for the memory check.
Budget to check: under 40 MB above the empty-board baseline and under 2 MB per idle
card. These are targets; no measured value was handed over.

## Why it matters

A user's typed input must survive scrolling and relaunch, but a secret or a draft
must never reach the board file, which can be shared. A stale state applied to a
new spec would show wrong numbers. A 256 KiB spec edited many times must not fill
the 2 MiB board file.

## Reproduction or evidence

Focused tests live in `Tests/RafuAppTests/GeneratedView/` (persistence filter,
budget, host create/update/reset, board integration that reads the saved file and
asserts a `_draft` key and a password value are absent, theme per Rafu theme).
Test counts for wave 3 were not part of the handoff.

## Verification

- `swift test --filter GeneratedView`
- `./script/format.sh --lint`, `./script/build.sh`, `./script/test.sh` (parallel),
  `./script/test.sh --no-parallel` (CI mode)
- Manual (Rafu Lightning only): toggle a Switch, quit, relaunch; Reset View by the
  three paths and Undo; open the saved board and look for `_draft` and a password
  value.

## Related code, ADRs, and phases

- `GeneratedViewCardModel.swift`, `GeneratedViewStatePersistence.swift`,
  `GeneratedViewBudget.swift`, `GeneratedViewActions.swift`,
  `GeneratedViewStreamSession.swift`, `JSONRenderTheme+Rafu.swift`,
  `GeneratedViewExport.swift`
- [ADR 0036](../decisions/0036-generated-views-on-the-ensemble-board.md)
- [`canvas-drag-observation.md`](canvas-drag-observation.md) (never write the
  document per frame)
- Phase: [`../plans/phases/ensemble-canvas.md`](../plans/phases/ensemble-canvas.md)
