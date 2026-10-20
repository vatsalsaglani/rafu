# Git process and parsing

- Applies to: local Git status, diffs, history, branch operations, staging, stash, and process capture
- Last verified: Swift 6.2, `/usr/bin/git` (Apple Git-155, 2.50.1) on macOS, 2026-07-18

## Rule or observed behavior

- Parse `git status --porcelain=v2 -z`; a rename/copy record consumes the next
  NUL-delimited field as its original path.
- Staged diffs work in unborn repositories, but unstage cannot assume `HEAD`.
  Use `git rm --cached --ignore-unmatch -- <path>` for the unborn case.
- Capture stdout and stderr into separate bounded temporary files. Waiting while
  unread `Pipe` buffers fill can deadlock a verbose Git child.
- Poll a running process with Swift cancellation checks and terminate the child
  when its task is cancelled. Always pass executable and argument arrays; never
  interpolate branch names or paths into a shell string.
- Validate revisions, branch names, and remotes with Git before using them in a
  later operation. Keep output/error messages bounded before showing them.
- Batch stage/unstage with `--pathspec-from-file=- --pathspec-file-nul`,
  streaming NUL-joined pathspecs over stdin instead of argv. Prefix every path
  with `:(literal)` — plain `git add -- <path>` still interprets pathspec-magic
  characters (`[`, `*`, leading `-`/`:`, ...) in the path itself, so a real file
  named `[a].txt` would silently glob-match a different file. `:(literal)`
  neutralizes that and the stdin form avoids `ARG_MAX` for large batches. This
  needs Git ≥ 2.26; Apple's bundled `/usr/bin/git` (Git-155 ≈ 2.50.1 as of
  2026-07-13) satisfies that. `GitCommandRunner.run` writes stdin `Data` to a
  temp file in the same per-run capture directory used for stdout/stderr and
  attaches a read `FileHandle`; it stays argv-only for every other argument.
  Verified directly against `/usr/bin/git` (not a Homebrew/PATH `git`), since
  that is the executable `GitCommandRunner` hardcodes.
- Parse `git diff --numstat -z`; ordinary records are one NUL-terminated
  `<added>\t<deleted>\t<path>` field. Binary files report `-\t-\t<path>`
  (no counts). Renames split across **three** NUL-terminated fields instead of
  one: `<added>\t<deleted>\t` (empty path, tab-terminated) followed by the old
  path and then the new path as their own records — naive single-record
  parsing misaligns every entry after a rename. Attribute counts to the new
  path. Untracked files never appear in numstat output at all (staged or not);
  callers needing an untracked file's size must read it from disk.
- Stage or unstage a textual hunk by slicing the exact hunk block from
  `GitFileDiff.rawPatch`, prefixing it with the exact file prologue, and passing
  that data over stdin to `git apply --cached -` or `git apply --cached
  --reverse -`. Never rebuild the patch from aligned display rows: alignment
  intentionally discards `\ No newline at end of file`, so reconstruction can
  change file contents. Do not add `--3way` or `--recount`; a context mismatch
  must fail atomically and ask the user to refresh the diff.
- List stashes with `git stash list -z
  --format=%gd%x1f%ct%x1f%gs`: records are NUL-delimited and fields use ASCII
  unit separator. Accept only canonical `stash@{n}` selectors whose `n` parses
  as a non-negative `Int`; reconstruct the selector from that integer for every
  apply, pop, or drop rather than accepting a string from UI state. Re-list and
  compare the complete selected entry immediately before a write because a
  stash index can shift when another process changes the list.
- Stash is always initiated by an explicit user action. `stash push` receives
  its optional message as a separate argv value, includes untracked files only
  when the user enables that option, and treats Git's successful "No local
  changes to save" result as a no-op. There is no automatic stash path. Apply
  keeps the entry; pop and drop require confirmation because they can discard
  the reference. A conflicted apply/pop refreshes both status and the stash list
  because Git may have changed the worktree even when the command exits nonzero.
- Blame one focused, saved file with `git blame --porcelain -- <relative-path>`
  from the already-resolved repository root. Validate that the path is
  nonempty, relative, NUL-free, and contains no empty, `.` or `..` components;
  keep `--` before it. Cap stdout/stderr at 32 MiB and do not retain a Git
  process. Porcelain may omit `author`, `author-time`, `summary`, and `boundary`
  after the first block for a commit, so cache that metadata by the full 40- or
  64-hex object ID and reuse it for later tab-prefixed source records.

## Why it matters

Status paths may contain spaces, tabs, and newlines; line parsing is lossy. Unborn
repositories are the exact state Rafu itself uses before its first commit. Bounded
capture and cancellation prevent a background Git action from hanging the editor
or retaining unbounded output. Pathspec magic is a real, silent correctness bug
for any batch operation over user-controlled filenames — Rafu's Source Control
tree view stages entire folders in one process, so a mismatched file would stage
or unstage the wrong content without any error.

Hunk staging is a new index write path. Keeping the Git-produced, one-file patch
on stdin prevents shell/argv injection, and refusing fuzzy or three-way fallback
prevents an apparently local action from merging stale context into the index.
The captured diff is bounded before slicing, the apply process is bounded and
cancellable, and the UI exposes the action only for modified files; added,
deleted, renamed, untracked, binary, and historical diffs retain whole-file
behavior.

Stash selectors are mutable ordinal references, not stable identities. Parsing
and rebuilding `stash@{n}` closes a ref-injection path, while the immediate
entry preflight prevents a stale row from targeting a different stash after the
list shifts. The message remains ordinary argv data and is never incorporated
into a revision or shell command. Confirmations keep destructive removal under
explicit user control, including pop's conditional drop-on-success behavior.

Blame's compact porcelain form avoids repeating commit metadata for every line,
but a parser that treats each block as self-contained silently loses most lines.
The SHA-keyed cache restores those lines without a second process. Rafu keeps
only the small `GitBlameLine` attribution model for the selected saved file;
the read-only canvas is destroyed on close, file-selection change, or workspace
change. It labels root/boundary commits in text rather than relying on color.

## Reproduction or evidence

The focused Git tests create temporary repositories covering unborn staging,
renames, history file lists, historical diffs, branch divergence, remote sync,
batch staging 100+ paths (including pathspec-magic and space-containing names)
in one process, and merged working-tree/staged numstat line counts. A rename's
`-z` numstat shape was verified directly against `/usr/bin/git` (`git diff
--numstat -z --find-renames --cached`) before writing `GitNumstatParser`.

The hunk fixtures verify a single hunk, the middle hunk of three, and exact
retention of the no-newline marker. The service round-trip starts with line 4
already staged, changes that same line again plus a distant line 20, stages only
the overlapping working-tree hunk, then reverses the staged hunk. The staged
patch contains `+line 4 final` and never `line 20 working`; after reverse apply,
the staged patch is empty and the working patch contains both final changes.

The stash parser fixtures cover empty, single, and multiple records; generated
`WIP on …` versus named `On …` subjects; fallback subjects; negative timestamps;
and malformed or noncanonical selectors. The service round-trip modifies one
tracked file and creates one untracked file, pushes with the include-untracked
option, verifies a clean tree and one canonical entry, applies it to restore
both files while retaining the entry, then drops it and verifies an empty list.
Apple Git's actual formatted output was also checked byte-for-byte: `%gd`, `%ct`,
and `%gs` were unit-separated and the record ended in NUL.

The blame fixtures cover two commits, boundary metadata, metadata reuse after a
deduplicated header, and malformed blocks. The repository round-trip commits a
two-line file under two authors and verifies the exact commit IDs, authors,
summaries, and root-boundary state returned for each final line.

## Verification

Run `swift test --filter Git`. Run the full suite afterward because process
isolation and shared workspace state are integration concerns.

## Related code, ADRs, and phases

- `Sources/RafuApp/Git/` (including `GitCommandRunner.swift`, `GitNumstatParser.swift`, `GitChangeTree.swift`)
- `Sources/RafuApp/Git/GitHunkPatchBuilder.swift`
- `Sources/RafuApp/Git/GitStashParser.swift`
- `Sources/RafuApp/Git/GitStashCoordinator.swift`
- `Sources/RafuApp/Git/GitBlameParser.swift`
- `Sources/RafuApp/Git/GitInlineBlameStore.swift` (GX1 cache key: path/headOID/revision)
- `Sources/RafuApp/Git/HunkPeekSlice.swift` (GX2 200-line cap slicing rawPatch)
- `Sources/RafuApp/Git/CommitGraphLayout.swift` (GX3 pure lane/edge model, ~8-lane visible cap)
- `Sources/RafuApp/Git/GitWorktreeParser.swift` (GX4 `git worktree list --porcelain`)
- `Sources/RafuApp/Services/GitService.swift` (including `loadMoreHistory()` for GX3 pagination)
- `Sources/RafuApp/Views/GitInspectorView.swift` (Source Control tree view; GX1/GX2/GX3/GX4/GX5 presentations)
- `Sources/RafuApp/Views/EditorInlineBlameView.swift` (GX1 drawBackground decoration)
- `Sources/RafuApp/Views/EditorHunkPeekPopover.swift` (GX2 NSPopover card)
- `Sources/RafuApp/Views/EditorBlameHoverPopover.swift` (GX2 NSPopover tooltip)
- `Tests/RafuAppTests/GitServiceTests.swift`
- `Tests/RafuAppTests/GitChangeTreeTests.swift`
- `Tests/RafuAppTests/GitHunkPatchBuilderTests.swift`
- `Tests/RafuAppTests/GitStashParserTests.swift`
- `Tests/RafuAppTests/GitBlameParserTests.swift`
- `Tests/RafuAppTests/CommitGraphLayoutTests.swift` (GX3 lane/edge layout)
- `Tests/RafuAppTests/GitWorktreeParserTests.swift` (GX4 porcelain parsing)
- `docs/plans/phases/pre-initial-push-workbench.md`
- `docs/plans/phases/git-depth-blame-stash-hunks.md`
- `docs/plans/phases/git-experience-and-worktrees.md` (GX1–GX5 scope and deferrals)
- `docs/decisions/0011-advanced-git-hunks-stash-blame.md`
- `docs/decisions/0013-git-experience-expansion.md` (ADR 0013 — Proposed)

## File-tree Git status badges (2026-07-18)

The sidebar decorates each file/folder row with a `git status --short`-style
marker (`M`, `A`, `??`, `D`, `R`, `U`, …) via `GitSnapshot.treeBadges(workspaceRoot:)`
(`Sources/RafuApp/Models/GitTreeBadge.swift`). Two nuances:

- **Path frame.** `GitChange.path` is relative to the **repository root**
  (`GitSnapshot.repositoryRoot`), which can sit *above* the opened workspace
  folder. Each change is reduced to a standardized absolute path
  (`repositoryRoot.appending(path:)`) and re-expressed relative to
  `workspaceRoot`; changes outside the open subtree are dropped. The map is
  keyed by **workspace-relative path** — the same identity
  `WorkspaceFileNode.relativePath` uses — so row lookups need no per-row
  symlink normalization (avoids the `/var` vs `/private/var` ambiguity that
  bites absolute-path matching).
- **Ancestor rollup.** Every ancestor directory of a change (up to, but
  excluding, the workspace root) gets the most severe descendant status by a
  fixed precedence (conflict > modified > renamed > typeChanged > added >
  copied > deleted > untracked), so a change shows at every level without
  expanding the tree.

The badge map is cached on `WorkspaceSession.gitTreeBadges`, rebuilt from
`gitSnapshot.didSet` — so it recomputes exactly once per snapshot refresh
(open, FSEvents `gitChanged`, save, stage/unstage, stash) and never per row.
Colors come from the existing `gitAdded`/`gitModified`/`gitDeleted`/
`gitUntracked`/`gitConflict` palette tokens; the letter is never the sole
channel (VoiceOver label + name tint for added/untracked/deleted).

## Inline blame, hunk peek, and commit graph (GX1–GX3, 2026-07-18)

**Inline blame** (GX1):
- Data source: `git blame --porcelain -- <relative-path>` for the active saved file only; cached per key `(path, headOID, document.revision)`.
- Debounce: ~300ms on caret-line change (via `RafuTextView.selectedRangeDidChange`). Never runs during typing; skipped entirely for dirty (unsaved) or guarded documents. Cache invalidated on save (`didSet` on `document.isDirty` and `document.revision`), workspace refresh, or `GitService.refreshGit()`.
- Presentation: **drawBackground decoration** (never `NSTextStorage` attributes). Ghost text after line end, author • relative time • summary, middle-truncated, rendered in `textMuted` color at ~85% size. Dirty document → annotation hidden (honest: blame is stale while editing).
- State: per-window toggle (`WorkspaceSession.isInlineBlameLikelyEnabled`), View menu + Command Palette action "Toggle Inline Blame". Off by default (calm default, discoverable).

**Hunk peek card** (GX2):
- Trigger: click a gutter change strip (`GitGutterHunkMarker` in the editor).
- Content: −/+ rows for that hunk **sliced verbatim from the existing `GitFileDiff.rawPatch`** (no re-diffing), prefixed with the exact file prologue. **Bounds:** 200-line cap on the slice (`HunkPeekSlice(rawPatch, at: hunk, maxLines: 200)`); if the hunk exceeds the cap, display "Open Full Diff" action only, no truncated preview.
- Footer: "Working Tree ↔ HEAD" label + Stage Hunk action set (no discard in v1 — destructive ops require full diff). Esc or click-outside dismisses; keyboard path via Command Palette "Peek Change at Line".
- Presentation: card anchored at the hunk using `NSPopover` (rounded-12 card header row + hairline + body on `cardBackground`; see ui-design-language reference for card anatomy).

**Blame hover card** (GX2):
- Trigger: hover over the inline blame ghost text OR gutter blame canvas.
- Content: header = author + relative time + absolute date; body = commit summary + sha chip; footer = Copy SHA, Show in History (jumps History detail selection), Open Blame Canvas.
- Presentation: `NSPopover` tooltip card, same anatomy as hunk peek. LSP hover keeps priority inside code (hover over identifiers still shows LSP type hints); blame hover anchors to the annotation/gutter, not text identifiers.

**Commit graph layout** (GX3):
- Input: paginated commit list from History (`GitHistoryPage`); commit parents captured via `%P` (space-separated, already in `GitHistoryCommit` by 2026-07-18).
- Model: pure `CommitGraphLayout` (deterministic, unit-tested, no Git I/O). Input → output: per-row lane index, incoming/outgoing edges, per-lane color (stable hash of the lane → small palette derived from theme git tokens `gitBranch`/`gitTag`/`gitRemote`).
- **Lane cap:** visible lanes capped at ~8; overflow handled with "+n more" indicator. Open stubs for edges pointing to unloaded parents (pagination boundary).
- Row anatomy: lane column (Canvas, ~14pt per lane, multiline lane crossings rendered vertically) | branch/tag chips (current branch ✓ check, upstream ↔, worktree ⚒ glyph when a worktree has this commit checked out) | commit subject | author • relative time.
- Header: search field for loaded commits (subject/author/sha substring match, explicitly labeled "in loaded commits" to set expectation — no repo-wide scan). Branch breadcrumb (current branch display). Fetch button with last-fetch relative time (explicit user action only — never automatic fetch).
- **Pagination note:** History pagination did NOT exist as a separate loading concept before GX3. `loadMoreHistory()` was added during this increment to progressively load commit pages, allowing graph layout to compute incrementally per loaded window without blocking the UI.

The row anatomy and lane colors above were replaced on 2026-10-20; see
"GitLens-style history graph" below.

**Worktree porcelain parsing** (GX4):
- Source: `git worktree list --porcelain` (one worktree per line, fields space-separated).
- Model: pure `GitWorktree { path, headOID, branch, isCurrent, isLocked, isPrunable }` (fixture-tested). Paths are absolute (`/path/to/worktree`); `isCurrent` is true for the active worktree only.
- Row display: folder name (last path component) + branch chip + ahead/behind counts vs. upstream (one `rev-list --left-right --count HEAD...upstream/branch` per worktree on expand only; cached) + "current" indicator.
- Open-in-new-window action reuses the existing `LauncherRequestRouter`/`WorkspaceWindowRegistry` path: enqueue a `LauncherRequest { openWorkspaceWindow(at: worktree.path) }` to the CLI socket, which the app processes by creating a new window and routing to that workspace. No duplicate Git parsing or window management logic.
- Dirty indicators deferred (GX4 shipped 2026-07-18 without them): would require one `git status` per sibling worktree on expand, revisit later.

**History pagination model** (introduced GX3):
- `loadMoreHistory()` method on `GitService` fetches the next page of commits (page size TBD, ~100–200). Returns `GitHistoryPage { commits, isComplete }`.
- Graph layout computed per loaded page; edges to unloaded parents drawn as open stubs (no projection or prediction).
- Explicit pagination boundaries: search field clearly states "in loaded commits"; fetch button visible in header so user can load more explicitly.
- Memory bounded: lazy loading prevents a 10k-commit repo from parsing all commits upfront.

## GitLens-style history graph (2026-10-20)

- Applies to: `CommitGraphLayout`, `GitCommitGraphView`, `GitCommitHoverCard`,
  `GitCommitDetailStore`, `GitService.commitDetail`/`remoteURL`,
  `GitHubRemoteURL`, `CommitGraphPalette`.
- Last verified: Swift 6.2, `/usr/bin/git` 2.54.0 (Apple Git-157), macOS 27,
  2026-10-20. Visual behavior (popover focus, row spacing) is NOT verified by
  a launch; see "Open questions".

### Observed behavior

- **`git show --format=%B%x00 --numstat -z` byte layout.** Git writes the
  message, the `%x00`, then its own NUL terminator and a newline before the
  first numstat record: `msg\n\0\0\n2\t1\tf.txt\0`. A merge under the
  default `--cc` writes `\0\0\0` with no newline. Split at the FIRST NUL and
  skip every following `0x00`/`0x0A` byte before `GitNumstatParser`, or the
  first record parses as `"\n2"` and is counted as binary.
- **Merges print no files by default.** `git diff-tree -r <merge>` prints
  nothing, and `git show <merge> -- <path>` prints a combined diff (or
  nothing) that `UnifiedDiffParser` cannot read. Add
  `--diff-merges=first-parent` (Git 2.31+) to `diff-tree`, `show` (diff),
  and the stats `show`, so all three agree.
- **`--decorate=full`** makes `%D` read `HEAD -> refs/heads/main,
  refs/remotes/origin/main, tag: refs/tags/v1`. A detached HEAD is the bare
  word `HEAD`. Strip the prefixes for display; never compare a full name to
  a short branch name without stripping.
- **Pass-through lanes.** A lane-assignment layout that records only edges
  touching a row cannot draw a continuous graph. Each row must also carry
  the lanes waiting for a commit further down (`passingLanes`) and whether
  its own lane continues up and down. Invariant, tested in
  `railsAreContinuousBetweenRows`: the lanes at a row's bottom
  (`lanesBelow`) equal the lanes at the next row's top.
- **Hollow merge ring in `Canvas`.** Fill the ring's disk with a copy of the
  context whose `blendMode = .clear` before stroking the ring. That erases
  the rails under the center, so the ring is hollow on any list background,
  with no guessed background color.
- **Hover popover on `List` rows.** One `.popover(isPresented:)` per row is
  fine when every binding reads one `@State hoverCardID`: only that row is
  presented, and the content closure runs only while presented. Close it on
  `onScrollPhaseChange` (macOS 15) when the phase is not `.idle`, or the
  card stays behind while its row scrolls away. Give the card its own
  `onHover` and a short dismissal grace (220 ms), or the card closes while
  the pointer travels into it to press Copy.
- **Keyboard selection in `List(selection:)`** changes the binding without
  the row's `onTapGesture`. If loading is tied to the tap, arrow keys expand
  the new row with the previous commit's files. Load from
  `onChange(of: selection)` too, and remember the ID the tap already asked
  for so one click loads once.
- **Remote URLs can hold credentials** (`https://user:token@github.com/...`).
  `GitCommitDetailStore` keeps only the page derived by `GitHubRemoteURL`
  (owner and repository); the raw string is dropped in the loading task.

### Round 5: narrow rows (2026-10-20, Swift 6.4, macOS 27.0.1)

- **An `HStack` with `layoutPriority` cannot express "subject floor, then
  pills, then subject".** In a ~300 pt sidebar the old row (subject
  priority 1, pills priority 2) hid the subject entirely on rows with refs
  and squeezed pills to "f…es"; the author showed as one letter. The fix is
  a pure plan (`GitCommitRowPlan`) applied by a custom `Layout`
  (`GitCommitRowLayout`) that measures each subview's ideal width once in
  `makeCache` (ADR 0013 round 5 lists the order).
- **Hiding a `Layout` subview.** A layout cannot remove a subview, so every
  pill density is a subview and the unused ones are placed with a zero-width
  proposal. Each slot is wrapped in `.frame(minWidth: 0, maxWidth:
  .infinity, alignment: .leading).clipped()` so a zero proposal draws
  nothing and an exact proposal truncates as usual; the frame's ideal size
  is still the child's ideal, so `sizeThatFits(.unspecified)` measures the
  real width. Built and unit-tested (the plan) only; the rendering is not
  yet confirmed by a launch.
- **`LayoutValueKey` under default `MainActor` isolation.** In `RafuApp` a
  plain `private struct …: LayoutValueKey` gets a main-actor-isolated
  conformance, and reading `subview[Key.self]` inside `Layout` methods fails
  to compile: "main actor-isolated conformance of '…' to 'LayoutValueKey'
  cannot be used in nonisolated context". Declare the key `nonisolated
  struct`. (Related: `nonisolated-extension-isolation-trap.md`.)
- **Commit bodies are hard-wrapped at ~72 columns.** Shown in a proportional
  font at another width they wrap raggedly. `GitCommitMessageReflow` joins
  lines within a paragraph and keeps list items, fenced/indented code, and
  trailer blocks; `GitCommitDetail.displayBody` runs it once when the
  detail loads, so no view body reflows text.

### Open questions (coordinator visual check)

- A SwiftUI popover can become the key window, so arrow keys may go to the
  card while it is open. The repository's tab preview avoids `.popover` for
  that reason (see `swiftui-macos-click-latency.md`). If this happens, move
  the card to an `NSPopover` that does not take key, or close it on key
  input.
- `List(.inset)` must place rows with no vertical gap, or the rails show
  breaks between 22 pt rows.

### Verification

`swift test --filter "CommitGraph|GitCommitGraphRowPlan|GitHubRemoteURL|GitCommitDetailStore|GitPanelPresentation|GitService"`.
The layout test `layoutScalesToThousandsOfCommits` lays out 5,000 synthetic
commits under a 2 s bound (a debug build takes milliseconds).

### Related

ADR 0013 amendment 2026-10-20; `Sources/RafuApp/Git/CommitGraphLayout.swift`,
`Sources/RafuApp/Views/GitCommitGraphView.swift`,
`Sources/RafuApp/Views/GitCommitHoverCard.swift`,
`Sources/RafuApp/Views/CommitGraphPalette.swift`,
`Sources/RafuApp/Git/GitCommitDetailStore.swift`,
`Sources/RafuApp/Git/GitHubRemoteURL.swift`.
