# Multi-folder and saved workspaces

- Applies to: `WorkspaceSession.roots` and `additionalRootTrees`, the Files
  tree root sections, multi-root search and quick open, the Source Control
  root picker, `.rafuworkspace` files (`RafuWorkspaceFile`), the saved list
  (`SavedWorkspaceListStore`), and the Workspaces window (X10).
- Last verified: macOS 27.0, Swift 6.2, Apple Git 2.54.0, 2026-10-20
  (`./script/test.sh`; repositories, summaries, and routing tests). First
  written on the Swift 6.2 Linux toolchain, 2026-10-18.

## Rule or observed behavior

- `rootURL` always means the **primary** (first) root. Terminals, Ensemble
  boards, language servers, the CLI, ignore-file suggestions, and restored
  tabs keep working on it unchanged. Extra roots live in
  `WorkspaceSession.additionalRootTrees`; each `WorkspaceRootTree` owns its
  own lazy listing, FSEvents watcher, quick-open index (built only on the
  first palette query), and security scope. Nothing is preloaded.
- The primary root's `WorkspaceRoot.id` is the descriptor ID, so it is stable
  while the workspace is open. The primary root cannot be removed.
- Git works on `gitRootURL`, the URL of the selected repository
  (`sourceControlRepositoryID`, the standardized folder path; nil means the
  primary root). Every Git function in `WorkspaceSession` binds
  `let rootURL = gitRootURL` and checks `self.gitRootURL == rootURL` after
  each await, so a result for an old repository is dropped when the user
  switches. `sourceControlRootID` is a computed compatibility view of a
  root-level selection.
- Repositories (`WorkspaceSession+Repositories.swift`,
  `WorkspaceGitRepositories`): each root inside a Git work tree (`.git`
  found by walking parents; no Git process), then the direct child folders
  of each root that hold a `.git` entry (nested repositories), by name. One
  directory listing per root, off the main actor; deeper nesting is not
  searched; at most 16. Discovery runs on open, add, remove, restore,
  Refresh, a storm, a `.git` that appears in an unlisted root or child
  folder, and a summary that finds a folder is no longer a repository.
- The Source Control navigator shows a Repositories section above Changes,
  History, and Branches: one 26 pt row per repository (selection pill radius
  6, like a Files-tree row), with name, branch (or "detached"), ahead and
  behind, a change-count capsule (staged, unstaged, untracked, and
  conflicted paths, each once), and a separate conflict capsule with a
  warning symbol. Counts are words in VoiceOver ("Branch main, 3 changes, 1
  conflict"), never color alone. A row is a button (Full Keyboard Access)
  with a context menu. One repository in a multi-folder workspace shows a
  single header line; a one-folder workspace with one repository shows
  nothing extra. With no explicit choice and a primary root that is not a
  repository, the first repository is selected.
- Summaries (`GitRepositorySummary`) come from one
  `git status --porcelain=v2 --branch` each (`GitService.snapshot(at:)`).
  The selected repository's summary follows `gitSnapshot` (no extra
  process). Others are fetched when the section appears or the list changes
  while it is visible, on Refresh, when FSEvents show that repository
  changed (immediately if the section is visible or it holds the active
  editor file, otherwise marked stale until the section appears), and once
  when the active editor file moves into a repository with no summary. One
  task drains a pending set, one `git status` at a time, so bursts coalesce.
  No process stays alive; nothing polls.
- Change routing: each root's FSEvents batch is mapped to the repositories
  it touches (`WorkspaceGitRepositories.impact`): a root-level repository by
  `gitChanged`/`treeChanged`, a nested repository by
  `nestedGitChangedDirectories` or a changed folder inside it. The selected
  repository gets `refreshGit()` (state) or `refreshGitSnapshotOnly()`
  (tree); the others get summary refreshes. Git-ignored paths are dropped
  first (`fsevents-ignore-filter.md`).
- File-tree Git badges are keyed relative to the root that holds the
  selected repository (`gitBadgeRootURL`), so a selected nested
  repository's badges land on its rows; `gitTreeBadge(forRelativePath:rootID:)`
  returns nil for rows of any other root. Badges for nested repositories
  that are not selected are deferred.
- The status bar and the title bar show the branch before Source Control
  is opened: `sourceControlBranchSummary` reads the status snapshot that
  opening or restoring the workspace already runs (`refreshWorkspace()`),
  so no `refreshGit()` (branches, history, merge state) starts before
  Source Control is shown. When the active editor file is in another
  repository, the status bar shows that repository's branch; a click selects
  it in Source Control and shows the navigator. Source Control never
  switches on its own when the active file changes.
- Restoration stores roots only, not the selected repository. A selected
  nested repository whose folder is gone falls back to the primary root.
- Search runs each root in order and prefixes paths with the root label
  (`lib/Sources/a.swift`) only when there is more than one root. Once the
  match limit is reached, later roots are skipped and the result is marked
  truncated. Quick open merges per-root ranked lists round robin.
- Root labels are the folder name; when two roots share a name the parent is
  added (`client/app`), and if that still collides the full path is used.
- Files-tree root sections (`WorkspaceRootSection`) are `DisclosureGroup`s
  with `RafuFileTreeDisclosureStyle`, like every folder group. They must
  never use the default style: one default-style group switches the whole
  Files `List` to `NSOutlineView`, and collapsing the primary root after a
  navigator switch then aborted the app
  (`list-custom-disclosure-group-style.md`). The header is a flat 26 pt row
  with the tree rows' insets: its 14 pt chevron cell is in the column of a
  depth-0 row's chevron, and it toggles on a click anywhere on the row,
  Return/Space, ←/→, and the VoiceOver default action. With more than one
  root, each root's direct children are depth 1, so their first indent guide
  runs down from the root chevron; a one-folder workspace keeps depth 0 and
  shows no root header. Collapse state is ephemeral window state
  (`collapsedRootIDs`); every root starts expanded.
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
Source Control Repositories section with two repositories and a nested one
(selection, change capsules, VoiceOver value, Tab/Space with Full Keyboard
Access), the status-bar branch at launch with Files shown and for a file in
another repository, Save Workspace As, reopen from Finder and from the
Workspaces window (⇧⌘1).

## Related code, ADRs, and phases

- `Sources/RafuCore/Workspace/WorkspaceRoot.swift`, `WorkspaceFileFormat.swift`,
  `SavedWorkspaceList.swift`
- `Sources/RafuApp/Workspace/**` (`WorkspaceSession+Repositories.swift`,
  `WorkspaceGitRepositories.swift`), `Views/WorkspacesListView.swift`,
  `Views/WorkspacesRootSections.swift` (`SourceControlRepositoriesSection`),
  `Views/WorkspaceStatusBar.swift`, `Views/WorkspaceSidebarView.swift`
- `Tests/RafuAppTests/MultiFolderWorkspaceTests.swift`
  (`MultiRepositoryWorkspaceTests`), `StatusBarBranchFormatterTests.swift`
- `docs/references/fsevents-ignore-filter.md`
- Phase: `docs/plans/phases/ensemble-canvas.md`, Addendum 2, X10.
