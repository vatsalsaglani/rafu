# Git experience — blame-in-editor, hunk peek, commit graph, worktrees, AI composer

## Status

IMPLEMENTED (2026-07-18). Increments GX1, GX2, GX3, GX5 shipped across three commits (477372b covers GX1/GX2/GX3 + ADR 0013; 9971888 covered GX4 worktrees; 6b46423 covers GX5); 714 tests pass (684→714, +30 pure-core); manual GUI verification remains owed.

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

DONE (477372b). GitLens' "You, 4 years ago • Supercharged" at end of the current line.

- Data: on-demand `git blame` for the **active file only**, reusing
  `GitService.blame(forRelativePath:at:)`; cached per `(path, headOID,
  document.revision)`; invalidated on save/refreshGit. Debounced ~300ms on caret-line change, never during typing, skipped for dirty/guarded documents. Cache key: `path/headOID/revision`.
- Presentation: ghost text after line end in `textMuted` at ~85% size — drawn as `drawBackground` decoration (never `NSTextStorage` attributes), author • relative time • summary, middle-truncated. Dirty document → annotation hidden.
- Control: off by default (GD2 resolved: quiet default). View-menu + palette toggle; per-window state on `WorkspaceSession`.

### GX2 — Blame hover card + hunk peek card

DONE (477372b). Two overlays sharing one card anatomy.

- **Blame hover** (on the ghost annotation / gutter blame hover): header = author + relative time + absolute date; body = commit summary + sha chip; footer actions = Copy SHA, Show in History, Open Blame Canvas. Reuses existing hover presentation channel; LSP hover keeps priority.
- **Hunk peek** (click a gutter change strip): card anchored at the hunk showing the −/+ rows sliced verbatim from the existing `rawPatch`, footer = "Working Tree ↔ HEAD" label + Stage Hunk action set. Esc/click-outside dismisses; keyboard path via command. **Bounds:** HunkPeekSlice 200-line cap, then "Open Full Diff" only.

### GX3 — History → Commit Graph

DONE (477372b). GitLens-style graph column inside the existing History section.

- Model: pure `CommitGraphLayout` — input: paginated commit list (parents via `%P`), output: per-row lane index, incoming/outgoing edges, lane colors (stable hash → theme git token palette). **Lane cap:** ~8 visible + overflow; open stubs for unloaded parents.
- Row anatomy: lane canvas column (~14pt/lane) | branch/tag chips (current branch check, upstream ⇄, worktree glyph) | subject | author • relative time.
- Header: search field (over loaded pages only, explicitly labeled "in loaded commits"), branch breadcrumb, fetch button with last-fetch relative time. **Note:** History pagination did NOT exist before; `loadMoreHistory()` was added during GX3.
- Deferred: activity minimap strip and avatars.

### GX4 — Worktrees (the agent-lane cockpit)

DONE (9971888). New collapsible section in Source Control.

- Data: `git worktree list --porcelain` parser → `GitWorktree` model (pure, fixture-tested). Listed on explicit section expand + after worktree mutations; no watching of sibling worktrees.
- Row: folder name + branch chip + ahead/behind vs its upstream + "current" check; dirty indicator deferred (GD4: requires per-worktree status).
- Actions: **Open in New Window** (existing window-routing path reused), **Compare with Current** (two-ref diff), **Add Worktree…** (sheet: new or existing branch + sibling-path default), **Remove…** (confirmation; never `--force`; real git error surfaced).

### GX5 — AI commit composer (visual, executes with UI-plan U3)

DONE (6b46423). Composer card per the design language.

- Message field on `fieldBackground`, header shows a scope chip ("12 staged files", "3 summarized — too large" truncation). Generation shows the existing `ProgressView` affordance; **no Stop button was added** — `WorkspaceSession` exposes no cancel API for AI generation, so a Stop control would be a behavior change out of this presentation-only scope. Generate/Commit split stays explicit (never auto-commit). Presentation only.

### GX6 — Deferred: activity visualizations

Contributor-bubbles (IMG_5378) deferred: needs measured evidence it earns its memory/CPU, and a real decision question. Revisit after GX1–GX5 ships.

## Durable decisions

ADR **0013** (authored in GX-lane, Proposed): scope of the Git experience
expansion — editor blame annotations, peek cards, bounded commit graph,
explicit worktree management; explicitly excludes background fetch/poll,
repo-wide search scans, avatars/identity lookup, and discard-from-peek.

## Resolved decisions (shipped as implemented)

- **GD1** Increment order: worktrees first (GX4 shipped 9971888) — highest daily value for agent workflow.
- **GD2** Inline blame default: off-until-toggled (shipped 477372b) — calm default, discoverable via View menu.
- **GD3** Graph lane colors: derived from theme git tokens (shipped 477372b) — stable hash → theme git token palette.
- **GD4** Worktree dirty indicators: deferred from v1 (GX4 shipped 9971888 without them) — requires per-worktree `git status`, revisit later.

## Verification contract

Per increment: build 0 warnings, full suite green, lint,
`--verify`; graph layout + worktree/blame parsers pure-unit-tested;
typing-path untouched (GX1 debounce proof: no blame work between
keystrokes); memory glance after GX3 with a 5k-commit page scroll;
keyboard + VoiceOver path for every new action; second window.
