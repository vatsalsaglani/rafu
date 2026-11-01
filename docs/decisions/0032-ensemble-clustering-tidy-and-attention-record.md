# 0032. Ensemble clustering Tidy Up and local attention record

- Status: Accepted (owner decision), 2026-11-01
- Related: [ADR 0025](0025-workspace-canvas-and-app-previews.md),
  [ADR 0023](0023-terminal-groups-and-saved-layouts.md)
- Phase: [`../plans/phases/ensemble-canvas.md`](../plans/phases/ensemble-canvas.md)
- Reference: [`../references/ensemble-clustering-tidy.md`](../references/ensemble-clustering-tidy.md)

## Context

Tidy Up on an Ensemble board flowed every card into rows in reading order
(`CanvasLayoutMath.tidy`). On a real board that produced a tall two-card-wide
column, not a tidy board:

- The row width had a hard cap of 1,800 pt, while terminal and local-web cards
  default to 640 × 420 pt. Two such cards plus the gap already filled a row,
  so the flow wrapped after two.
- Rows were filled in reading order, which ignores which cards belong together,
  so linked cards were separated and unrelated cards became neighbours.
- Rows were ragged, because each row's height came from its tallest card.
- Frames were not laid out: their rects are derived from their members
  (`CanvasFrameLayout.fitted`). After the flow scattered a frame's members, the
  frame re-fitted around the scattered set and overlapped other cards. In
  `normalizeFrames` this happens as `followed` doing nothing (the members did
  not move as a group) and `fitted` then growing the frame.

The owner asked for a layout that reflects how the board is actually used, and
decided the layout should also know which cards the user works in.

## Decision

1. **Tidy Up is a clustering layout, not a grid flow.** The grid is removed
   (`CanvasLayoutMath.tidy`/`tidyGap` deleted); no grid mode is kept and there
   is no user choice between the two. The new pure, deterministic layout lives
   in `Sources/RafuApp/Canvas/Domain/CanvasClusterLayout.swift`: a frame and its
   members are one rigid unit, loose drawings attach rigidly to the nearest
   unit, clusters are the connected components over links, the most attended
   unit anchors its cluster, and clusters pack into shelves shaped like the
   visible board. A frame with members is never emitted; members move by an
   exact integer translation so `followed` no-ops and `fitted` reproduces the
   translated frame, which is what stops the old overlap.
2. **Tidy Up zooms to fit afterwards** (`fitAll()`), because the whole point of
   the arrangement is only visible when the board is framed.
3. **Attention is recorded per card in a workspace-local sidecar**, not derived
   from topology alone and not thrown away at the end of the session:
   `Sources/RafuApp/Canvas/Domain/CanvasNodeAttention.swift` plus sidecar
   load/record/forget in `CanvasPersistenceStore`.
4. **The record is NOT part of `CanvasDocument` and NOT in the `.rafuensemble`
   file.** Attention changes on every focus change. Inside the document, every
   focus change would mark the document dirty and trigger a save, and for a
   file-bound board it would rewrite a file the user has committed to their
   repository. Attention is a local usage hint, not board content, so it must
   never show up in a diff.
5. **Privacy rule: durations and dates only.** A record is two numbers
   (`seconds`, `lastFocused`) keyed by card id. No titles, paths, commands,
   note text, terminal output or URLs are stored, and nothing about attention is
   logged.

## Alternatives considered

- **Topology only (no attention record).** Cluster by links and pick the hub by
  link count and position. Simple, nothing persisted, nothing private.
  Rejected by the owner: on a board where most cards are unlinked it gives no
  ordering at all, and the card the user actually lives in does not anchor
  anything.
- **Session-only attention (in memory, dropped on quit).** No file, no privacy
  surface. Rejected: the first Tidy Up after reopening a board — the common
  case — would have no signal, so the layout would be unstable between runs.
- **Persisted sidecar (chosen).** One small JSON file per workspace beside the
  existing board index, outside the document and outside the `.rafuensemble`
  file, with decay, caps, pruning and an atomic 0600 write.

## Consequences

- Tidy Up now depends on local state that is not in the document, so the same
  board can tidy differently on two Macs. That is intended: the layout follows
  this user's work.
- A new on-disk artifact exists per workspace. It must fail soft: a corrupt,
  oversized, wrong-version, symlinked or locked sidecar yields an empty record
  and never fails a board load.
- Attention must be fed only by coarse focus transitions. A per-frame,
  per-keystroke or terminal-output feed is not allowed; it would be both a
  performance cost and a far more revealing record.
- Deleting a board forgets its record. Caps bound the file (see the reference
  note for the exact values).
- Removing the grid means there is no fallback presentation if a user prefers
  rows. Reintroducing one would need a new decision.

## Revisit trigger

A user asks for a reading-order or grid arrangement again, or the attention
record needs to carry anything beyond a duration and a date.
