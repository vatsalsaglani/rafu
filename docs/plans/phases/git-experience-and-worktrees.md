# Git experience — blame-in-editor, hunk peek, commit graph, worktrees, AI composer

## Status

Planned (2026-07-18). Direction brief only — no implementation started.
Sibling to [`ui-flat-modern-refresh.md`](ui-flat-modern-refresh.md): every
surface here adopts that plan's design language (flat layered surfaces,
hairlines, card overlays, chips, scarce accent). References: five
GitLens screenshots supplied by the user (inline blame ghost text + hunk
peek card; rich blame hover; commit graph with lanes/branch chips/search;
worktrees tree with per-worktree status and actions; contributor-activity
bubbles). File anchors reflect the tree at `19cdfd7`; the repository wins
when they disagree.

## Why this fits Rafu specifically

The user's own workflow *is* worktree fan-out with CLI coding agents (six
agent lanes shipped this way on 2026-07-18). A worktrees surface plus
open-in-new-window (already powered by the IPC/window-routing work) makes
Rafu the natural cockpit for that workflow. Everything below stays inside
AGENTS invariants: explicit user action for every mutation, argv-array git
only, no background polling, no full-repo preload, bounded output, no
automatic fetch.

## Existing assets to build on (verified)

- `GitBlameParser` + `GitBlame` models + read-only blame canvas (lane G3).
- `GitGutterHunkParser` (gutter change strips) + `GitHunkPatchBuilder`
  (verbatim rawPatch slicing) + stage/unstage plumbing (lane G1).
- `GitHistoryPage` pagination + history detail (changes per commit).
- `GitSnapshot` branch/upstream/ahead-behind; stash (G2).
- Editor hover-tooltip infrastructure (`RafuTextView.hoverAction`,
  `NSPopover` tooltip) — reusable presentation channel for the blame hover.
- `LauncherRequestRouter`/`WorkspaceWindowRegistry` — open a folder in a
  new or existing window (worktree → window is one call).
- AI commit generation with smallest-first budgeting + truncation
  disclosure (Git-scale package).

## Increments

### GX1 — Inline line blame (ghost annotation)

GitLens' "You, 4 years ago • Supercharged" at end of the current line.

- Data: on-demand `git blame` for the **active file only**, reusing
  `GitService.blame(forRelativePath:at:)`; cached per `(path, headOID,
  document.revision)`; invalidated on save/refreshGit. Never runs during
  typing — computed on caret-line change with a ~300ms debounce, only for
  saved (non-dirty) files, skipped entirely for guarded documents.
- Presentation: ghost text after line end in `textMuted` at ~85% size —
  drawn like existing editor decorations (never storage attributes),
  author • relative time • summary, middle-truncated. Dirty document →
  annotation hidden (honest: blame is stale while editing).
- Control: off by default? (decision GD2). View-menu + palette toggle
  "Toggle Inline Blame"; per-window state on `WorkspaceSession`.
- Tests: cache invalidation, dirty suppression, formatting; decoration
  drawing covered by the existing editor-decoration test pattern.

### GX2 — Blame hover card + hunk peek card

Two overlays sharing one card anatomy (design-language: header row +
hairline + body + footer action row).

- **Blame hover** (on the ghost annotation / gutter blame hover): header
  = author + relative time + absolute date; body = commit summary + sha
  chip; footer actions = Copy SHA, Show in History (jumps History
  selection), Open Blame Canvas. Reuses the existing hover
  presentation channel; LSP hover keeps priority inside code —
  blame hover anchors to the annotation/gutter, not identifiers.
- **Hunk peek** (click a gutter change strip): card anchored at the hunk
  showing the −/+ rows for that hunk sliced verbatim from the existing
  `rawPatch` (no re-diffing), footer = "Working Tree ↔ HEAD" label +
  Stage Hunk / Discard-free action set (no discard in v1 — destructive),
  Open Full Diff. Esc/click-outside dismisses; keyboard path via a
  command ("Peek Change at Line").
- Bounds: peek renders ≤ 200 hunk lines, then "Open Full Diff" only.

### GX3 — History → Commit Graph

GitLens-style graph column inside the existing History section (no new
window, editor-hosted detail unchanged).

- Model: pure `CommitGraphLayout` — input: the existing paginated commit
  list (`GitHistoryPage`, parents per commit added to the history format
  via `%P`), output: per-row lane index, incoming/outgoing edges, lane
  colors (stable hash → small palette derived from theme git tokens).
  Pure + unit-tested; pagination preserved (lanes computed per loaded
  window; edges to unloaded parents draw as open stubs).
- Row anatomy: lane canvas column (Canvas, ~14pt/lane, cap visible lanes
  ~8 with overflow "+n") | branch/tag chips (current branch check,
  upstream ⇄, worktree glyph when a worktree has it checked out) |
  subject | author • relative time. Selection keeps today's
  detail-loading behavior.
- Header: search field (subject/author/sha filter over loaded pages —
  explicitly labeled "in loaded commits", no repo-wide scan), branch
  breadcrumb, fetch button with last-fetch relative time (explicit fetch
  only — never automatic).
- Deferred from this increment: the activity minimap strip and
  avatars (no identity/network source; initials chip optional later).

### GX4 — Worktrees (the agent-lane cockpit)

New collapsible section in Source Control between Changes and History.

- Data: `git worktree list --porcelain` parser → `GitWorktree { path,
  headOID, branch, isCurrent, isLocked, isPrunable }` (pure,
  fixture-tested). Listed on explicit section expand + after worktree
  mutations; no watching of sibling worktrees.
- Row: folder name + branch chip + ahead/behind vs its upstream (one
  `rev-list --left-right --count` per row, on expand only) + "current"
  check; dirty indicator deferred (requires per-worktree status —
  decision GD4).
- Actions (explicit, menu + trailing icons): **Open in New Window**
  (existing window-routing path), **Compare with Current** (two-ref diff
  via existing `GitDiffScope.between`), **Add Worktree…** (sheet: new or
  existing branch + sibling-path default, runs `git worktree add`),
  **Remove…** (confirmation; never `--force`; refuses dirty/locked with
  the real git error surfaced).
- This section is also where a running agent lane becomes glanceable:
  branch + ahead-count answers "which lanes have landed commits" without
  leaving the main window.

### GX5 — AI commit composer (visual, executes with UI-plan U3)

- Composer card per the design language: message field on
  `fieldBackground`, header chips showing scope ("12 staged files",
  "3 summarized — too large" truncation disclosure that already exists as
  text), streaming generation fills the field with a subtle progress
  affordance and a Stop button; Generate/Commit split stays explicit
  (never auto-commit — invariant). Amend/merge-guidance banner restyled
  as a quiet card. No behavior change — presentation only.

### GX6 — Deferred: activity visualizations

The contributor-bubbles reference (IMG_5378) is recorded as deliberately
deferred eye-candy: needs measured evidence it earns its memory/CPU, and
a real question about what decision it helps the user make. Revisit after
the rest ships.

## Durable decisions

ADR **0013** (authored in GX-lane, Proposed): scope of the Git experience
expansion — editor blame annotations, peek cards, bounded commit graph,
explicit worktree management; explicitly excludes background fetch/poll,
repo-wide search scans, avatars/identity lookup, and discard-from-peek.

## Open decisions (user)

- **GD1** Increment order: worktrees first (GX4 — my recommendation:
  highest daily value for the agent workflow) vs graph first (GX3 —
  most visual "wow").
- **GD2** Inline blame default: off-until-toggled (recommended — calm
  default, discoverable via View menu) vs on by default.
- **GD3** Graph lane colors: derived from theme git tokens (recommended)
  vs fixed rainbow palette.
- **GD4** Worktree dirty indicators: skip in v1 (recommended — needs one
  `git status` per sibling worktree) vs include on explicit refresh.

## Verification contract

Per increment: build 0 warnings, full suite green, lint,
`--verify`; graph layout + worktree/blame parsers pure-unit-tested;
typing-path untouched (GX1 debounce proof: no blame work between
keystrokes); memory glance after GX3 with a 5k-commit page scroll;
keyboard + VoiceOver path for every new action; second window.
