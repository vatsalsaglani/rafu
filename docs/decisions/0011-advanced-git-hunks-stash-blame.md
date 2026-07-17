# ADR 0011: Add explicit hunk staging, stash, and bounded blame

- **Status:** Proposed
- **Date:** 2026-07-18

## Context

Rafu's Source Control surface already supports repository status, whole-file
staging, diffs, and history. The user asked for a deeper, GitLens-like local
workflow: stage an individual hunk, deliberately set work aside in a stash,
and inspect who last changed each line. Rafu is still a focused repository
companion, so adopting those jobs must not turn it into a general Git client or
add background repository indexing.

Hunk staging is a new write path to the Git index. The existing unified-diff
rows are designed for display and omit Git's `\ No newline at end of file`
marker, so a patch reconstructed from those rows can silently change content.
The exact bounded stdout captured as `GitFileDiff.rawPatch` remains available.

Stash was not a Phase 6 controlled-expansion candidate. The user explicitly
approved it for this fan-out lane, taking it off that candidate list for this
work. Stash ordinal references can shift, and pop or drop can remove the only
convenient reference to saved work.

Blame can be presented either inside the editor gutter or in an editor-hosted
read-only canvas. The gutter would put attribution beside the source, but it
would couple this lane to the TextKit editor boundary, compete with line-change
markers, and make dense authorship data harder to expose without color. The G0
contract also deliberately stores only bounded attribution metadata, not a
second copy of the file's source text.

## Decision

- Hunk staging is available only for textual hunks of modified files in live
  working-tree or staged diffs. Rafu slices the selected hunk and the exact file
  prologue from `rawPatch`, preserving every byte represented by the patch, and
  sends it over stdin to `/usr/bin/git apply --cached -`. Unstaging adds only
  `--reverse`. It never adds `--3way` or `--recount`; stale context fails
  atomically, after which Rafu refreshes the repository and diff.
- Added, deleted, renamed, untracked, binary, historical, and between-revision
  diffs keep whole-file or read-only behavior. Line-range staging is not part of
  this decision.
- Stash is always an explicit user action. The Source Control sheet provides an
  optional message and include-untracked choice; the menu and command palette
  provide the conservative tracked-only action. There is no automatic stash.
- Stash apply, pop, and drop accept only a validated non-negative `Int`. Rafu
  reconstructs `stash@{n}`, re-lists and matches the complete entry before a
  mutation, and requires confirmation before pop or drop. A conflict refreshes
  status and the stash list because Git may have changed the worktree even when
  it exits nonzero.
- Blame runs one bounded `/usr/bin/git blame --porcelain -- <relative-path>` for
  the focused, saved file. The parser caches deduplicated metadata by full
  object ID. Rafu displays line number, author, short commit, age, summary, and
  textual root-boundary state in an editor-hosted read-only canvas. Closing it,
  selecting another file, or changing workspace discards the attribution.
- All Git processes use executable-plus-argument arrays, bounded capture,
  cancellation, and the repository's existing noninteractive environment. No
  Git process persists and no operation preloads repository-wide blame data.
- The menu and command-palette additions are minimal, additive integration
  points. They receive no new shortcut because existing command ownership and
  shortcut conflicts are shared integration concerns.

## Alternatives considered

1. **Reconstruct a patch from aligned rows.** Rejected because the display
   parser is intentionally lossy around no-newline markers and would make an
   index write depend on presentation state.
2. **Use `git add -p` or a persistent interactive Git process.** Rejected
   because Rafu needs deterministic native controls, cancellable bounded
   commands, and no terminal protocol or persistent Git child.
3. **Add `--3way` or `--recount` for convenience.** Rejected because either can
   hide drift between the visible diff and the index mutation. The selected
   captured patch must apply exactly or not at all.
4. **Auto-stash around another operation.** Rejected because it changes the
   worktree and stash list without a dedicated user decision.
5. **Annotate the TextKit gutter.** Rejected for MVP. It crosses the editor-lane
   ownership boundary, competes with existing gutter semantics, and encourages
   color-dominant authorship signalling. A native gutter treatment may be
   revisited after the editor contracts and accessibility design stabilize.
6. **Retain source text with blame metadata.** Rejected because the open editor
   already owns live text and the G0 model intentionally bounds observable
   state to attribution.

## Consequences

- Rafu gains the high-leverage local Git actions the user requested while every
  mutation remains visible and explicit. A selected hunk round-trips exactly
  through the index; context drift becomes a refreshable error rather than a
  fuzzy merge.
- The stash list is a view of mutable Git state, not stable storage. Preflight
  reduces the chance of acting on a shifted ordinal, but external Git activity
  can still make an operation fail; failure is surfaced and state is refreshed.
- Blame costs one process and attribution proportional to one focused file. It
  does not provide inline source highlighting, repository-wide ownership, or
  background caching.
- The read-only canvas is less spatially compact than gutter annotations, but
  it is removable, avoids editor coupling, exposes semantics in text, and keeps
  the file-text ownership invariant intact.
- Removing these features later leaves the established status/diff/history
  model intact: the hunk builder, stash parser/coordinator, blame parser/canvas,
  and command entries are separable additions.

**Revisit triggers:** validated demand for line-range staging; evidence that a
native blame gutter can remain accessible and coexist with editor markers; or
workflows that require stable named work snapshots beyond Git's ordinal stash
model. Any automatic stash proposal requires a new explicit user decision.

**Merge note:** the integration owner should change this ADR from Proposed to
Accepted only when merging the lane and append its row to the shared decision
index.

**Related:** `docs/plans/phases/git-depth-blame-stash-hunks.md`,
`docs/references/git-process-and-parsing.md`,
`Sources/RafuApp/Git/GitHunkPatchBuilder.swift`,
`Sources/RafuApp/Git/GitStashParser.swift`,
`Sources/RafuApp/Git/GitBlameParser.swift`,
`Sources/RafuApp/Services/GitService.swift`,
`Sources/RafuApp/Views/GitInspectorView.swift`, and
`Sources/RafuApp/Views/EditorCanvasView.swift`.
