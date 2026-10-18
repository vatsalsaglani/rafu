# Multi-folder and saved workspaces

- Applies to: `WorkspaceSession.roots` and `additionalRootTrees`, the Files
  tree root sections, multi-root search and quick open, the Source Control
  root picker, `.rafuworkspace` files (`RafuWorkspaceFile`), the saved list
  (`SavedWorkspaceListStore`), and the Workspaces window (X10).
- Last verified: Swift 6.2 Linux toolchain (syntax, lint, and RafuCore logic
  in a scratch package), 2026-10-18. Not yet built on macOS; the macOS
  `./script/test.sh` gate is still required.

## Rule or observed behavior

- `rootURL` always means the **primary** (first) root. Terminals, Ensemble
  boards, language servers, the CLI, ignore-file suggestions, and restored
  tabs keep working on it unchanged. Extra roots live in
  `WorkspaceSession.additionalRootTrees`; each `WorkspaceRootTree` owns its
  own lazy listing, FSEvents watcher, quick-open index (built only on the
  first palette query), and security scope. Nothing is preloaded.
- The primary root's `WorkspaceRoot.id` is the descriptor ID, so it is stable
  while the workspace is open. The primary root cannot be removed.
- Git works on `gitRootURL` (the chosen Source Control root, default the
  primary). Every Git function in `WorkspaceSession` binds
  `let rootURL = gitRootURL` and checks `self.gitRootURL == rootURL` after
  each await, so a result for an old root is dropped when the user switches.
  File-tree Git badges are keyed relative to the Git root;
  `gitTreeBadge(forRelativePath:rootID:)` returns nil for rows of any other
  root. The picker appears only when more than one root is inside a Git work
  tree (`.git` found by walking parents; no Git process).
- Search runs each root in order and prefixes paths with the root label
  (`lib/Sources/a.swift`) only when there is more than one root. Once the
  match limit is reached, later roots are skipped and the result is marked
  truncated. Quick open merges per-root ranked lists round robin.
- Root labels are the folder name; when two roots share a name the parent is
  added (`client/app`), and if that still collides the full path is used.
- `.rafuworkspace`: UTType `dev.rafu.workspace` (conforms to `public.json`),
  exported and registered as an Owner document type in the Info.plist that
  `script/build_and_run.sh` writes (index 2, checked by `plutil`). JSON keys:
  `formatVersion` (1), `displayName`, `folders[]` (`bookmark` data and
  `lastKnownPath`), optional `primaryIndex`, reserved `layoutReference`.
  Reads are bounded to 1 MiB before parsing; a newer `formatVersion` is
  refused with "Update Rafu"; a bad `primaryIndex` falls back to the first
  folder. Writes are atomic (`Data.write(options: .atomic)`) to the URL the
  user chose in the save panel. Bookmarks are tried with security scope,
  then plain; the last known path is the fallback.
- The saved list is `saved-workspaces.json` in the identity's Application
  Support root (never `UserDefaults`), at most 50 entries, atomic writes,
  bounded reads; damaged or newer data reads as an empty list.
- A workspace file from Finder or the Workspaces window never replaces an
  open workspace: `WorkspaceFileOpenRouter` focuses the bound window, else
  fills an empty window, else opens a new one.
- Relaunch restoration stores extra roots (`RestorableWorkspace.additionalRoots`,
  optional on decode) and the bound file path. Tabs from extra roots are not
  restored (their paths are not relative to the primary root).

## Why it matters

Most of the app assumes one root. Keeping `rootURL` primary avoided a
rewrite of every caller; the Git rebinding and badge gating stop one root's
Git state from decorating another root's rows.

## Reproduction or evidence

`Tests/RafuCoreTests/WorkspaceRootListTests.swift`,
`WorkspaceFileFormatTests.swift`, and `SavedWorkspaceListTests.swift` passed
(22 tests) in a scratch SwiftPM package on Linux. App behavior tests are in
`Tests/RafuAppTests/MultiFolderWorkspaceTests.swift` (macOS only).

## Verification

```bash
swiftc -parse -swift-version 6 <changed files>
swift-format lint --strict <changed files>
./script/test.sh            # macOS
./script/build_and_run.sh --verify
```

Manual: add a second folder, check both root sections, search, ⌘P, the
Source Control picker with two repositories, Save Workspace As, reopen from
Finder and from the Workspaces window (⇧⌘1).

## Related code, ADRs, and phases

- `Sources/RafuCore/Workspace/WorkspaceRoot.swift`, `WorkspaceFileFormat.swift`,
  `SavedWorkspaceList.swift`
- `Sources/RafuApp/Workspace/**`, `Views/WorkspacesListView.swift`,
  `Views/WorkspacesRootSections.swift`, `Views/WorkspaceSidebarView.swift`
- Phase: `docs/plans/phases/ensemble-canvas.md`, Addendum 2, X10.
