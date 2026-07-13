# Git process and parsing

- Applies to: local Git status, diffs, history, branch operations, staging, and process capture
- Last verified: Swift 6.2, `/usr/bin/git` (Apple Git-155, 2.50.1) on macOS, 2026-07-13

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

## Why it matters

Status paths may contain spaces, tabs, and newlines; line parsing is lossy. Unborn
repositories are the exact state Rafu itself uses before its first commit. Bounded
capture and cancellation prevent a background Git action from hanging the editor
or retaining unbounded output. Pathspec magic is a real, silent correctness bug
for any batch operation over user-controlled filenames — Rafu's Source Control
tree view stages entire folders in one process, so a mismatched file would stage
or unstage the wrong content without any error.

## Reproduction or evidence

The focused Git tests create temporary repositories covering unborn staging,
renames, history file lists, historical diffs, branch divergence, remote sync,
batch staging 100+ paths (including pathspec-magic and space-containing names)
in one process, and merged working-tree/staged numstat line counts. A rename's
`-z` numstat shape was verified directly against `/usr/bin/git` (`git diff
--numstat -z --find-renames --cached`) before writing `GitNumstatParser`.

## Verification

Run `swift test --filter Git`. Run the full suite afterward because process
isolation and shared workspace state are integration concerns.

## Related code, ADRs, and phases

- `Sources/RafuApp/Git/` (including `GitCommandRunner.swift`, `GitNumstatParser.swift`, `GitChangeTree.swift`)
- `Sources/RafuApp/Services/GitService.swift`
- `Sources/RafuApp/Views/GitInspectorView.swift` (Source Control tree view)
- `Tests/RafuAppTests/GitServiceTests.swift`
- `Tests/RafuAppTests/GitChangeTreeTests.swift`
- `docs/plans/phases/pre-initial-push-workbench.md`

