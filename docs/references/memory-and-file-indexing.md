# Lazy file tree and background file-name index

- **Applies to:** the Files sidebar tree, `WorkspaceSession` tree/index state,
  `WorkspaceFileService`, `WorkspaceFileNameIndex`, the command palette's file
  mode, and FSEvents-driven refresh
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-15

## Rule or observed behavior

- The sidebar tree is lazy and expansion-driven, not eagerly recursive.
  `WorkspaceFileNode` no longer carries `children`; `WorkspaceFileService`
  exposes `listDirectory(rootURL:relativeDirectoryPath:)`, which lists exactly
  one directory level. `WorkspaceSession` keeps `loadedChildren: [String:
  [WorkspaceFileNode]]` (keyed by workspace-relative path, `""` for the root)
  and `expandedDirectories: Set<String>`, populated only as the sidebar
  expands a directory (`loadChildrenIfNeeded`) or a breadcrumb click reveals
  one (`revealInSidebar`, which expands and loads every ancestor). The
  sidebar itself is a recursive `DisclosureGroup` tree
  (`WorkspaceFileTreeItem` in `WorkspaceSidebarView.swift`), not an
  `OutlineGroup`, because `OutlineGroup` needs a fully materialized
  `children` key path up front — exactly what lazy loading avoids.
- **Git monorepo optimization (user/system-side):** on very large Git
  monorepos, `git ls-files` performance can be accelerated by setting
  `core.fsmonitor = true` (to use the system's native file-monitor daemon
  instead of `lstat` stat calls) and `core.untrackedCache = true` (to cache
  untracked-file enumeration across status calls). Rafu does not set these
  automatically; they are repository-specific tuning options that must be
  configured by the workspace owner. Users experiencing slow Git status
  refresh on a 50k+ file monorepo should consider `git config core.fsmonitor
  true && git config core.untrackedCache true` in the repo root to avoid
  repeated full filesystem scans during `git ls-files` index builds.
- `refreshWorkspace()` re-lists the root plus every already-materialized
  directory (the keys of `loadedChildren`), never anything the sidebar
  hasn't opened. FSEvents batches carry a new
  `WorkspaceChangeSet.changedDirectoryRelativePaths: Set<String>`
  (workspace-relative parent directory of every surviving changed path, `""`
  for root-level changes); `WorkspaceSession` re-lists only the changed
  directories that are materialized, and prunes a directory (and every
  materialized descendant, matched by relative-path prefix) that fails to
  re-list because it no longer exists. **Storm circuit breaker:** on a
  burst of filesystem activity, `WorkspaceChangeClassifier` detects a storm
  when event occurrences pass the `stormSurvivingPathThreshold` (strict `>`
  1,000 surviving paths at both treeChanged sites) OR the
  `stormChangedDirectoryThreshold` (strict `>` 200 distinct changed
  directories). The isStorm flag is computed **before** clearing
  `changedDirectoryRelativePaths` (order is critical — clearing first makes
  the directory threshold incapable of firing); on a storm, the directory
  set is cleared to keep the change set bounded and signal "full refresh".
  `WorkspaceSession.handleExternalChanges` then does exactly one
  `await refreshWorkspace()` (root + materialized-directory re-list + prune
  + git snapshot + single coalesced index rebuild) instead of the
  per-changed-directory `refreshChangedDirectories` loop. The non-storm path
  is byte-for-byte unchanged; gitChanged and open-document-reload tails run
  identically in both paths. This design keeps memory cost bounded regardless
  of batch size.
- ⌘P's file mode is backed by a separate, dedicated actor,
  `WorkspaceFileNameIndex`, holding one compact `[String]` of
  workspace-relative paths — never the sidebar's `WorkspaceFileNode` tree.
  Git workspaces are indexed with one `git ls-files --cached --others
  --exclude-standard --deduplicate -z` at the workspace root (no
  `--full-name`, so a repo-subdir workspace stays workspace-relative), which
  is `.gitignore`-aware for free. A non-git workspace, or a workspace where
  `git ls-files` fails, falls back to a cancellable `FileManager` enumeration
  sharing `WorkspaceFileService.excludedDirectories`. Both sources cap at
  `WorkspaceFileNameIndex.maximumEntries` (200,000) and report
  `isTruncated`.
- `WorkspaceSession` owns the index (`@ObservationIgnored`) and exposes only
  `fileIndexState` (`.idle` / `.building` / `.ready(count:isTruncated:)`) and
  a `fileIndexGeneration` counter bumped on every build completion.
  `requestFileIndexRebuild()` coalesces to one build in flight plus at most
  one trailing rebuild, so FSEvents storms and back-to-back Git operations
  (checkout/pull/merge/rename/create, all of which call `refreshWorkspace()`)
  never pile up overlapping `git ls-files`/enumerator work. The palette's
  file-mode query runs in a `.task(id:)` keyed by **both** the search term
  and `fileIndexGeneration` — omitting the generation from the key is exactly
  how a build that completes while the palette is open (or was already open
  when the build started) leaves the palette showing empty results forever.
- New ranking function `CommandPaletteMatcher.rankFiles(query:paths:limit:)`
  is additive; the existing `rank(query:candidates:)` used by command/symbol
  mode is untouched (its behavior is pinned by
  `SearchCommandPaletteTests`). `rankFiles` scores the filename (last path
  component, boosted by a flat tier above any path-only score) and the full
  path independently and keeps the higher of the two, so a strong filename
  match always outranks a weaker path-only match regardless of nesting
  depth; ties break on shorter path, then lexicographically. It is `async
  throws` and checks `Task.checkCancellation()` every 4,096 candidates so a
  keystroke can supersede an in-flight rank over a large index.
- **Symlink-resolution nuance in `FileManager.enumerator(at:)`:** on macOS,
  `FileManager.default.temporaryDirectory` returns a path through the
  `/var` → `/private/var` symlink. `FileManager.enumerator(at:)` can return
  child `URL`s with the symlink already resolved (`/private/var/...`) even
  when the **starting** URL passed to it was not resolved, while
  `contentsOfDirectory(at:)` does not do this. Computing a relative path by
  dropping the root URL's `path.count` prefix from an enumerated child's
  `path` silently produces garbage (a truncated fragment, not a crash) if
  only one side is resolved. Fix: resolve **both** the root and every
  enumerated child via `.resolvingSymlinksInPath().standardizedFileURL`
  before computing the relative path — `WorkspaceSearchService.scan` already
  does this; `WorkspaceFileNameIndex.enumeratedPaths` now matches it. This
  only surfaces with roots under the temp-directory symlink (real workspace
  roots opened via Finder/the file importer are typically already resolved),
  which is exactly the shape most filesystem-enumeration unit tests use —
  write relative-path assertions for any new enumerator-based code, not just
  `.name`/`.lastPathComponent` ones, or this class of bug stays invisible.

## Why it matters

The plan budget is roughly under 150 MB idle resident memory for a local
workspace, with no full repository preload and syntax parsing only for open
buffers. An eagerly recursive tree and a palette that flattens that same
recursive tree do the opposite on a monorepo: both walk (and retain) every
file on open, before the user has expanded a single folder or ever pressed
⌘P. Splitting "what the sidebar shows" (bounded by expansion) from "what ⌘P
can find" (the whole workspace, via a compact background index) keeps both
proportional to what the user actually interacts with instead of workspace
size.

## Reproduction and evidence

Synthetic ~100,000-file Git monorepo (40 top-level packages × 25 modules ×
100 files, `git init && git add -A && git commit`), built and measured
against the staged `dist/Rafu.app` (`./script/build_and_run.sh --verify`),
sampling the running process with `ps -o rss= -p <pid>`. Debug build; numbers
are directional, not a Release/Instruments measurement.

| Point | RSS |
|---|---|
| Idle, no workspace open | ~29–38 MB |
| Immediately after opening the 100k-file workspace (root listing + git snapshot + index build kickoff) | ~85 MB (peak) |
| Settled ~10 s after open (index build — one `git ls-files` process — complete) | ~47–49 MB |
| After a `⌘P`-directed keystroke via System Events (best-effort; the test host's screen was locked, so this is unconfirmed visually) | ~34 MB |
| Peak during a 2,000-file `touch` burst across ~1,000 directories (FSEvents debounce + coalesced index rebuild) | ~70 MB |
| Settled ~10 s after the burst | ~36 MB |
| Peak during a 2,000-file `touch` burst across ~700 directories on a 1,129-dir/3,300-file synthetic repo (storm circuit breaker active; debug build) | ~67 MB (~0.6 MB rise over pre-burst ~67 MB baseline) |
| Settled ~10 s after storm burst | ~61 MB |
| Symbol-index build on 28,000-file repo (8,000 .swift files ~40,000 declarations; 20,000 .txt filler; debug build; 2026-07-15) — peak during parse | ~137 MB |
| Symbol-index settled after build | ~129 MB |

All points stayed well under the 150 MB budget; no crash, fault, or error
appeared in `log show --predicate 'process == "Rafu"'` across the run. The
sidebar itself never materializes more than the root listing in this
scenario, since the test could not drive real UI expansion clicks (locked
screen) — the manual GUI pass (expand deep folders, confirm
`isTruncated`/"Indexing…" states, drag/rename/create/context menus, second
window, keyboard reachability) is still pending human verification.

## Verification

```bash
swift build
swift test
./script/format.sh --fix && ./script/format.sh --lint
./script/build_and_run.sh --verify
```

Focused tests: `WorkspaceFileServiceTests` (single-level, non-recursive
listing), `WorkspaceChangeClassifierTests` (`changedDirectoryRelativePaths`),
`WorkspaceFileNameIndexTests` (git/.gitignore path, non-git enumerator
fallback and its shared exclusions, cap/truncation, empty-query prefix,
filename-over-path ranking, reset, query cancellation), and
`SearchCommandPaletteTests` (`rankFiles` filename-over-path at depth,
tie-breaking, empty query, cancellation; `rank`/`score` untouched).

## Related code, ADRs, and phases

- `Sources/RafuApp/Models/WorkspaceFileNode.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift`
- `Sources/RafuApp/Services/WorkspaceFileService.swift`
- `Sources/RafuApp/Services/WorkspaceFileNameIndex.swift`
- `Sources/RafuApp/Services/WorkspaceLivenessService.swift`
- `Sources/RafuApp/Views/WorkspaceSidebarView.swift`
- `Sources/RafuApp/Views/CommandPaletteView.swift`
- `Sources/RafuApp/Views/EditorBreadcrumbView.swift`
- `docs/plans/phases/pre-initial-push-workbench.md`
- `docs/references/local-editor-vertical-slice.md`
- `docs/references/concurrency.md`
