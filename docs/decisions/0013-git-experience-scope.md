# ADR 0013: Git experience scope — inline blame, peek cards, bounded commit graph

- **Status:** Proposed
- **Date:** 2026-07-18

## Context

[`docs/plans/phases/git-experience-and-worktrees.md`](../plans/phases/git-experience-and-worktrees.md)
lays out six increments (GX1–GX6) extending Rafu's Git surface toward a
GitLens-like local workflow, adopting the flat card/chip design language from
ADR 0012. Worktrees (GX4) and the AI commit composer's presentation (GX5)
already landed in the flat-UI refresh. This ADR scopes the remaining
interactive increments that touch the editor and the history section: inline
line blame (GX1), a blame-hover card and a hunk-peek card (GX2), and a bounded
commit graph inside the existing History section (GX3). GX6 (contributor
activity visualizations) stays deliberately deferred and is out of scope here.

ADR 0011 rejected a TextKit gutter blame treatment for the original blame
canvas, reasoning that gutter annotation "crosses the editor-lane ownership
boundary, competes with existing gutter semantics, and encourages
color-dominant authorship signalling," while flagging a revisit trigger:
"evidence that a native blame gutter can remain accessible and coexist with
editor markers." GX1 answers that trigger narrowly: it does not annotate the
gutter's line-number column. It draws ghost text *after* the end of the caret
line, in the existing decoration-drawing path (`drawBackground`, never
`NSTextStorage`), reusing the same non-color-dominant discipline the current
line highlight, indent guides, and bracket borders already establish. This
ADR treats that as a narrow amendment to ADR 0011's boundary, not a reversal:
the gutter's line-number/change-strip column itself stays untouched by blame;
only a click on its existing change strip gains the GX2 peek action.

## Decision

**Scope for this ADR:**

- **GX1 — Inline line blame.** On-demand `git blame` for the active,
  saved (non-dirty) file only, debounced ~300ms on caret-line change,
  cached per `(path, headOID, revision)`, rendered as ghost text ("Author •
  relative-time • summary", middle-truncated) after the caret line in
  `textMuted` at ~85% font size. Off by default (**GD2**); toggled per
  window via the View menu / command palette, never persisted across
  launches.
- **GX2 — Blame-hover card + hunk-peek card.** Two popovers sharing one
  card anatomy (header/hairline/body/footer). The blame-hover card anchors
  to the inline-blame annotation and shows author, relative and absolute
  time, commit summary, and a sha chip, with Copy SHA / Show in History /
  Open Blame Canvas actions. The hunk-peek card anchors to a gutter
  change-strip click (or the "Peek Change at Line" command) and slices the
  already-captured working-tree `GitFileDiff.rawPatch` rows for exactly one
  hunk (`HunkPeekSlice`, ≤200 rows, else summary + Open Full Diff only),
  offering Stage Hunk and Open Full Diff. There is no discard action in
  either card.
- **GX3 — Bounded commit graph.** A pure `CommitGraphLayout` over the
  already-paginated `GitHistoryPage` (parents already carried via `%P`)
  assigns each commit a lane, incoming/outgoing edges, and a stable color
  index, capped at ~8 visible lanes with an overflow indicator; edges to a
  parent outside the loaded window draw as an open stub rather than
  crashing or silently truncating. Lane colors are derived from theme Git
  tokens (**GD3**) — `gitAdded`, `gitModified`, `gitDeleted`, `info`,
  `accent`, `warning`, cycled by lane index — never a fixed rainbow
  palette, so the graph inherits every theme's palette automatically. The
  graph replaces only the commit-row rendering inside
  `GitInspectorView.historyView`; selection, the tap-to-load-detail path,
  and the `GitHistoryDetail` panel are unchanged. A "Load More" action adds
  the first explicit history pagination continuation
  (`WorkspaceSession.loadMoreHistory()`); the existing single-page
  `refreshGit()` load is unchanged.

**Explicit exclusions**, all consistent with the invariants in AGENTS.md:

- No background fetch or poll. `gitLastFetchedAt` only ever advances from an
  explicit Fetch action; nothing schedules one automatically.
- No repository-wide search scans. The commit-graph search field filters
  only the commits already loaded into `GitHistoryPage`, and its label says
  so ("in loaded commits").
- No avatar or identity-provider lookup. Author display uses the raw
  `git log`/`git blame` author name; there is no Gravatar-style network
  fetch and no attempt to resolve a local Git email to a richer identity.
- No discard-from-peek. The hunk-peek card offers Stage Hunk and Open Full
  Diff only; a destructive discard action is deliberately excluded from a
  popover — it stays behind the existing, more deliberate diff-canvas path.

## Alternatives considered

1. **Put inline blame in the gutter's line-number column.** Rejected —
   this is exactly what ADR 0011 rejected; it would still compete visually
   with the change-strip and caret-line-number emphasis already living
   there.
2. **Re-diff for the hunk-peek card instead of slicing `rawPatch`.**
   Rejected — a second `git diff` call per peek duplicates work the
   standalone diff canvas already paid for and risks a hunk boundary
   mismatch between the two reads; slicing the already-captured diff keeps
   peek and stage-hunk consistent with `stageHunk(_:)`'s existing
   `GitHunkPatchBuilder` contract.
3. **Fixed rainbow lane-color palette for the commit graph.** Rejected
   (**GD3**) — a hardcoded palette would clash with a theme's Git token
   colors (e.g., Dracula vs. GitHub Light) and duplicate color decisions
   the theme JSON already owns.
4. **Inline blame on by default.** Rejected (**GD2**) — a ghost-text
   annotation at every caret line is a persistent, glanceable Git surface;
   Rafu's calm-by-default posture (see AGENTS.md) favors an explicit,
   one-keystroke opt-in over an always-on overlay.
5. **Background-fetch before showing the commit graph's "last fetched"
   label.** Rejected — fetch is a network operation with (SSH) trust and
   latency consequences; it must stay an explicit user action per the
   standing "no automatic fetch" invariant.

## Consequences

- Inline blame adds one more per-buffer decoration-drawing path
  (`RafuTextView.drawInlineBlameAnnotation`) beside the existing current-line
  highlight, indent guides, and bracket borders, all sharing the same
  "never touch `NSTextStorage`" discipline — no new coupling to the syntax
  pipeline.
- The blame-hover and hunk-peek cards reuse the existing hover-popover
  presentation channel (`NSPopover`, teardown-on-edit/scroll/keystroke),
  so GX2 adds no second popover subsystem — only new card content and a
  bounded pure slicer.
- `CommitGraphLayout` is a pure, fully unit-testable function from
  `[GitCommitSummary]` to `[GraphRow]`; it never spawns a process and never
  grows unbounded (visible-lane cap, per-window-only edges), so a very wide
  or very long loaded history degrades to an overflow indicator instead of
  an unbounded canvas.
- `WorkspaceSession.loadMoreHistory()` is Rafu's first explicit history
  pagination continuation; `GitHistoryPage.hasMore`'s existing
  `commits.count == requestedCount` formula is preserved across merged
  pages by carrying the merged `requestedCount` forward, so no model or
  parser change was needed.
- Deferring GX6 (contributor-activity visualizations) keeps this ADR's
  scope to features with a clear, immediate decision the user makes with
  them (who wrote this line, what does this hunk contain, how do branches
  relate) rather than exploratory eye-candy.

**Revisit triggers:** measured evidence the ~300ms inline-blame debounce or
per-file blame cache is insufficient on a large or high-churn repository;
demand for a repository-wide blame/graph search (would need explicit,
bounded indexing — a new ADR); demand for worktree-aware graph lanes (a
worktree glyph per lane) once GX4's dirty-indicator question (GD4) is
revisited; or GX6 being picked back up with measured memory/CPU evidence.

**Merge note:** the integration owner should change this ADR from Proposed
to Accepted only when merging the lane and append its row to the shared
decision index.

**Related:** [`docs/plans/phases/git-experience-and-worktrees.md`](../plans/phases/git-experience-and-worktrees.md),
[`0011-advanced-git-hunks-stash-blame.md`](0011-advanced-git-hunks-stash-blame.md),
[`0012-flat-workbench-chrome.md`](0012-flat-workbench-chrome.md),
`Sources/RafuApp/Editor/InlineBlameAnnotation.swift`,
`Sources/RafuApp/Services/InlineBlameStore.swift`,
`Sources/RafuApp/Editor/RafuTextView.swift`,
`Sources/RafuApp/Editor/CodeEditorView.swift`,
`Sources/RafuApp/Editor/EditorGutterRulerView.swift`,
`Sources/RafuApp/Git/HunkPeekSlice.swift`,
`Sources/RafuApp/Git/CommitGraphLayout.swift`,
`Sources/RafuApp/Views/GitBlameHoverCard.swift`,
`Sources/RafuApp/Views/GitHunkPeekCard.swift`,
`Sources/RafuApp/Views/GitCommitGraphView.swift`,
`Sources/RafuApp/Views/GitInspectorView.swift`, and
`Sources/RafuApp/Models/WorkspaceSession.swift`.
