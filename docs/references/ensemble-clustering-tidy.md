# Ensemble clustering Tidy Up and the attention sidecar

- Applies to: `Sources/RafuApp/Canvas/Domain/CanvasClusterLayout.swift`,
  `Sources/RafuApp/Canvas/Domain/CanvasNodeAttention.swift`,
  `Canvas/Persistence/CanvasPersistenceStore.swift`,
  `Canvas/Integration/CanvasBoardState.swift`,
  `Canvas/Integration/WorkspaceCanvasStore.swift`,
  `Canvas/Integration/WorkspaceCanvasActions.swift`,
  `Canvas/Views/WorkspaceCanvasView.swift`
- Last verified: Swift 6.2 language mode, macOS Darwin 27.0.0, 2026-11-01

## Rule or observed behavior

### Why the old grid Tidy Up gave two columns

`CanvasLayoutMath.tidy` flowed cards in reading order into rows with a hard
1,800 pt row cap. Terminal and local-web cards default to 640 × 420 pt, so two
cards plus the gap filled a row and the flow wrapped after two — a tall
two-wide column. Rows were also ragged (row height = tallest card in the row),
and reading order split linked cards apart.

Frames were the worse failure. A frame's rect is derived from its members
(`CanvasFrameLayout.fitted`). The flow scattered the members, so in
`normalizeFrames` the `followed` step found no common translation and did
nothing, and `fitted` then grew the frame around the scattered set, overlapping
unrelated cards. `tidy`/`tidyGap` are removed.

### The clustering layout (pure, deterministic)

- Nodes are sorted by `(y, x, id)` first, so the result does not depend on the
  order of the input array.
- **Units.** A frame plus its members (transitively) is one rigid unit;
  union-find merges overlapping or nested frames. A frame that has members is
  never emitted — members move by an exact integer translation, so `followed`
  no-ops and `fitted` reproduces the translated frame. An empty frame is an
  ordinary card. Unit bounds include the frame rects.
- **Loose drawings** (shape, stroke, text, service icon; no link, not in a
  frame) attach rigidly to the nearest unit within `attachDistance` = 120 pt.
  Otherwise they group with each other by the same 120 pt proximity into loose
  units, which are placed last.
- **Clusters** are the connected components over links ∪ units. The hub is
  chosen by (attention sum, link count, position). BFS from the hub places
  children on rays — level 1 spread evenly, deeper levels fanning out from the
  parent's heading — at distance `parent reach + child reach + 24 pt gap`.
- A separation pass of at most 80 sweeps (hub fixed) removes overlap; if any
  overlap remains it falls back to a shelf layout, so **the result never
  overlaps**.
- **Cluster order:** loose units last; otherwise latest `lastFocused`, then
  attention, then size, then first position.
- **Packing:** shelves with target width
  `max(widest cluster, sqrt(Σ (w + 72)(h + 72) × aspect))`, where `aspect` is
  the viewport width over height clamped to 0.5–3 (default 1.6); cluster gap
  72 pt.
- The laid-out top-left lands on the old content top-left. Translations are
  integers and clamped to ±50,000. **Sizes are read, never written.**
- One `edit` = one undo step and one save. `fitAll()` runs after it (a viewport
  change, not a document change).

### Attention: what feeds it

Events are only: `focusedCardID` changes, `contentIsActive` changes, board view
appear/disappear, and app resign/become-active. There is **no** per-frame, per
keystroke or terminal-output path. Selection and an agent `node_update` do not
count as attention.

- Weights: content-active 1.0×, focused-without-content 0.3×
  (`attentionFocusOnlyWeight`).
- A stretch under 1 s is dropped (`attentionMinimumSegment`); a single stretch
  counts at most 30 min (`attentionSegmentSeconds`), which bounds a sleeping Mac.
- Decay half-life 7 days, computed lazily on read (`decayed(at:)`); no timer.
- Flush at most every 30 s (`attentionFlushInterval`), plus on board-view
  disappear, app resign-active, board close (`forgetClosed`) and `flushAll`
  (workspace switch / quit). A failed write keeps the time for the next flush.

### The sidecar file

`<Canvases>/<workspace>/ensemble-attention.json`, beside the existing
`ensemble-files.index`.

```json
{ "version": 1,
  "boards": [ { "id": "…", "cards": [ { "id": "…", "seconds": 12.3, "lastFocused": "…" } ] } ] }
```

- `seconds` rounded to 0.1; dates to whole seconds.
- Atomic write, mode 0600, under the board `flock`.
- Read is non-following, regular-file only, at most 256 KiB
  (`attentionFileBytes`). Corrupt, oversized, wrong-version, symlinked or
  locked → empty record. **It never fails a board load.**
- Caps: `seconds` ≤ 100 h; entries older than 90 days or for cards that no
  longer exist are dropped; at most 100 cards per board
  (`CanvasLimits.cards`); at most 10 boards, newest kept. Deleting a board
  forgets its record.
- Content rule: durations and dates only — no titles, paths, text or URLs — and
  nothing is logged.

## Why it matters

The layout is the only consumer of the attention record, and it is the reason
the record exists at all; changing one without the other makes Tidy Up
unstable. The frame translation rule is the non-obvious part: any future
layout that moves a frame's members without a single shared integer
translation will reintroduce the overlapping-frame bug. And the record is
deliberately outside `CanvasDocument` and the `.rafuensemble` file, so no new
code may move it there (see ADR 0032): every focus change would dirty and save
the document and rewrite a user-committed file.

## Reproduction or evidence

- Old bug: a board of 640 × 420 pt terminal cards tidied into a 2-wide column
  against the 1,800 pt row cap. The regression test
  `CanvasClusterLayoutTests` asserts those cards are no longer a 2-wide column.
- Tests: `Tests/RafuAppTests/Canvas/CanvasClusterLayoutTests.swift` — 14 layout
  tests and 2 board tests, including a frame enclosing only its own members, one
  undo restoring the pre-Tidy layout, and attention ordering the clusters.
  `Tests/RafuAppTests/Canvas/CanvasNodeAttentionTests.swift` — 20 tests,
  including the sidecar round trip, the 0600 mode, that only the expected JSON
  keys are present, recovery from a bad file, and that a symlink is not
  followed. The old `tidy` test was removed from `CanvasLayoutMathTests.swift`.

## Verification

Run on 2026-11-01 (Swift 6.2 language mode, macOS Darwin 27.0.0):

```bash
./script/format.sh --lint     # clean
./script/build.sh             # clean; only the pre-existing SwiftTerm
                              # "missing creator for mutated node … bundle" notice
./script/test.sh              # parallel: 2,931 tests in 210 suites + 278 in 16, passed
./script/build_and_run.sh --verify   # exit 0
```

The parallel run above was repeated after the search-palette change, so it
describes the final tree. No `--no-parallel` run is recorded for this
increment.

**Not verified by hand:** Tidy Up on a real board; undo of a Tidy; zoom-to-fit
with Reduce Motion; the sidecar file on disk; cluster spacing with 640 × 420 pt
terminals at 16:10; the quit-path `flushAll`.

## Related code, ADRs, and phases

- [ADR 0032](../decisions/0032-ensemble-clustering-tidy-and-attention-record.md)
  — the decision and the rejected alternatives.
- [ADR 0025](../decisions/0025-workspace-canvas-and-app-previews.md),
  [ADR 0023](../decisions/0023-terminal-groups-and-saved-layouts.md).
- Phase: [`../plans/phases/ensemble-canvas.md`](../plans/phases/ensemble-canvas.md).
- `CanvasLayoutMath.swift` also gained `CanvasCardContent.isWhiteboardDrawing`,
  which is how the layout tells a loose drawing from a card.
