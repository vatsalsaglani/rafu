# FSEvents ignore filter

- Applies to: `WorkspaceLivenessService.flush()`,
  `WorkspaceChangeClassifier`, `WorkspaceIgnoredPathFilter`
  (`Sources/RafuApp/Services/`), and the change handlers
  `WorkspaceSession.handleExternalChanges(_:)` and
  `WorkspaceRootTree.apply(_:)`.
- Last verified: macOS 27.0 (Darwin 27.0.0), Swift 6.2, Apple Git 2.54.0
  (Apple Git-157), 2026-10-20.

## Rule or observed behavior

- The classifier drops a fixed set of noise folders (`.git` internals,
  `.build`, `.swiftpm`, `dist`, `DerivedData`, `node_modules`, `.DS_Store`).
  Before this filter, a write into any other ignored folder (`.venv`,
  `.next`, `tmp`, `.logs`, `.pytest_cache`, `.ruff_cache`, `__pycache__`)
  marked the tree changed. Each debounced batch then ran `git status`, a
  `git ls-files` file-index rebuild, and a symbol-index update. A dev server
  or a test runner that writes all the time kept the CPU busy while the
  editor was idle.
- Now, when a batch marks the tree changed, `flush()` asks Git which paths
  are ignored, off the main actor, and classifies again:
  - An ignored path does not mark the tree changed and does not count toward
    a storm. It goes to `ignoredDirectoryRelativePaths`, which only re-lists
    a tree folder that is already listed. An open document in an ignored
    folder still reloads.
  - One `git check-ignore --stdin -z` runs for each repository in the batch
    (the root, and each nested repository with its own rules). The input is
    each path and each parent folder.
  - The answer is remembered. An ignored path is remembered as is. An
    ignored folder covers every path inside it only after one
    `git ls-files -z -- :(literal)<folder>` shows that Git tracks nothing in
    it. Later writes into a remembered place start no process at all.
  - The memory restarts when the index, HEAD, a ref, or packed-refs changes
    (root or nested), when a `.gitignore` or a `.git/info/exclude` changes,
    and when the watcher stops. It is cleared above 1,024 entries.
  - Every bound fails open: above 8,192 paths to ask about, outside a Git
    work tree, or when Git fails, no path is dropped.
- `git check-ignore` facts (verified with Apple Git 2.54.0):
  - A path inside an ignored folder is reported (`.venv/lib/a.py` for
    `.venv/`), also when the path no longer exists.
  - An existing folder is reported with or without a trailing slash.
  - A tracked file that matches a pattern is not reported (index-aware;
    do not pass `--no-index`).
  - A path inside an untracked nested repository is not reported by the
    outer repository, and it is not an error.
  - Exit 0 means some paths are ignored, 1 means none, 128 means not a
    repository.
- `.git` events now count as Git changes for `HEAD`, `index`,
  `packed-refs`, and `refs/**` except `*.lock`. Before, a ref change alone
  (an external commit or fetch that does not rewrite the index) did not
  refresh Source Control. `child/.git/...` state changes are reported as
  `nestedGitChangedDirectories`.

## Why it matters

Idle CPU is a product budget. A folder that Git ignores never changes
`git status`, the `git ls-files --exclude-standard` file index, or the
symbol index, so refreshing them for it is wasted work. The tracked-file
check matters because Git ignores a folder pattern but still tracks a
force-added file in it; covering the folder blindly would hide changes to
that file.

## Reproduction or evidence

1. Open a repository with `.venv/` in `.gitignore`.
2. Run `while true; do date > .venv/x; sleep 0.5; done` in a terminal.
3. Before: `git status` and `git ls-files` processes every debounce. After:
   one `check-ignore` and one `ls-files` for the first batch, then none.

Tests: `Tests/RafuAppTests/WorkspaceIgnoredPathFilterTests.swift` (plan,
memory, bounds, and a real Git repository with a nested repository and a
force-added file), `WorkspaceChangeClassifierTests.swift` (ignored paths,
refs, nested `.git`, candidates, ignore-rule changes).

## Verification

```bash
swift test --filter "WorkspaceIgnoredPathFilterTests|classifier"
./script/test.sh
```

## Known limits

- A change to the global excludes file (`core.excludesFile`) is not seen;
  the memory refreshes on the next index or ref change.
- Ignore rules of a nested repository apply only to the repositories that
  discovery lists (direct child folders of a root).

## Related code, ADRs, and phases

- `Sources/RafuApp/Services/WorkspaceLivenessService.swift`,
  `WorkspaceIgnoredPathFilter.swift`
- `docs/references/memory-and-file-indexing.md`,
  `docs/references/multi-folder-workspaces.md`
