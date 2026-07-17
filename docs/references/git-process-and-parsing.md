# Git process and parsing

- Applies to: local Git status, diffs, history, branch operations, staging, stash, and process capture
- Last verified: Swift 6.2, `/usr/bin/git` (Apple Git-155, 2.50.1) on macOS, 2026-07-17

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
- `Sources/RafuApp/Services/GitService.swift`
- `Sources/RafuApp/Views/GitInspectorView.swift` (Source Control tree view)
- `Tests/RafuAppTests/GitServiceTests.swift`
- `Tests/RafuAppTests/GitChangeTreeTests.swift`
- `Tests/RafuAppTests/GitHunkPatchBuilderTests.swift`
- `Tests/RafuAppTests/GitStashParserTests.swift`
- `Tests/RafuAppTests/GitBlameParserTests.swift`
- `docs/plans/phases/pre-initial-push-workbench.md`
- `docs/plans/phases/git-depth-blame-stash-hunks.md`
