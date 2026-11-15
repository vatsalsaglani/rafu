# Terminal last working folder

- Applies to: `Sources/RafuApp/Terminal/TerminalWorkingFolder.swift`,
  `TerminalGroupModel.swift`, `TerminalForegroundProcess.swift`,
  `WorkspaceTerminalController.swift`, `TerminalGroupRestorationCodec.swift`,
  `TerminalGroupRuntime.swift`, `TerminalGroupView.swift`,
  `Models/WorkspaceSession.swift`, `Canvas/Adapters/CanvasTerminalCard.swift`.
  Tests: `Tests/RafuAppTests/TerminalLastWorkingFolderTests.swift`.
- Last verified: Xcode with the macOS 27.2 SDK (26B118), Swift 6 language mode,
  Darwin 27.2.0, Mac17,13, 2026-11-15. Both test modes on `main` passed
  (parallel and `--no-parallel`: 3640 tests in 294 suites). The user confirmed
  the restore in Rafu Lightning.

## Rule or observed behavior

A terminal starts in the folder where its shell last was. ADR 0023 (2026-11-15
amendment) allows this and narrowly supersedes "observed working directory stays
live-only".

**Storage.**

- `TerminalPaneLaunchProfile` has an optional `lastWorkingFolder`. Workspace
  restoration and Ensemble board records carry it.
- The value is workspace-relative, symlink-resolved, inside the root, and
  revalidated on restore and again on start. It is never absolute and never a
  command.
- A value equal to `startingFolder` is stored as nil. A remote workspace
  (`rootURL` nil) clears it.
- It is never in a user-named saved layout. `TerminalGroupRestorationCodec.savedRecord`
  strips it.

**Start fallback order.** Last folder if usable, then starting folder if usable,
then the workspace root (ADR 0023 amendment 2, 2026-11-15, supersedes the earlier
"no root substitution" rule).

- The root is used only when the starting folder is gone (`lstat` ENOENT,
  `TerminalWorkspaceFolder.isMissing`) and the root is usable.
- A folder that exists but is not usable keeps the refusal: a symlink that
  escapes the workspace, a file, an unreadable folder, or a dangling symlink at
  the path. This is a security rule. The test "Start All rejects a saved symlink
  escape before it reveals or starts a pane" pins it.
- Remote workspaces are unchanged. Restart Shell on an exited pane is unchanged:
  it still refuses when its starting folder is gone.
- The saved starting folder is kept, so the pane uses it again if it returns.
- `TerminalStartFolderResolver.resolve` has a required `isMissing:` argument.
- Restoration validates in the same order. The codec has a new startable case,
  `.workspaceFolderFallback`. A pane with a working last folder and a missing
  starting folder can start.
- Labels read the session set `terminalPanesStartingInWorkspaceFolder` (filled
  during window and Ensemble restoration, cleared when the pane starts), never
  the disk. Stopped pane: "Start this pane when you are ready. Its saved folder is
  gone, so it starts in the workspace folder." Ensemble card: "Saved folder is
  gone. Starts in the workspace folder." A folder deleted while the app runs uses
  the root at start, but the label changes only after the next restore.

**Unsaved Terminal Group tabs are restored** (ADR 0023 amendment 2).

- A group with its own editor tab enters the window payload and the saved editor
  layout. Panes, splits, names, starting folders, last folders, tab position and
  selection return. All panes are stopped; no process and no command.
- Closed or hidden groups do not return. Ensemble groups, groups a card shows,
  and groups with a card on any open board are restored by the board only. A group
  whose saved layout was deleted while it was closed stays dropped.
- No schema change: the open-tab record already allowed no saved layout.
- Caps are unchanged: with more than 20 groups, insertion stops at 20 with the
  existing bounded notice. Named layouts still strip the last folder. If the
  saved-layout store cannot list layouts during restore, no group is restored
  (unchanged). An old payload with no terminal field still gives "One saved
  Terminal Group could not be restored."

**Where the folder comes from.**

- OSC 7 (`hostCurrentDirectoryUpdate`) is one source. Accept an empty host,
  `localhost`, or the `gethostname()` name and its first label, case-insensitive.
  Do not use `ProcessInfo.hostName`: it may block on a lookup. A report from a
  remote host is ignored, not cleared. Percent-encoded paths are decoded.
- OSC 7 is not enough. Stock zsh and bash in Rafu send no OSC 7; fish,
  starship and powerlevel10k do.
- `proc_pidinfo(pid, PROC_PIDVNODEPATHINFO)` and `pvi_cdir.vip_path` cover every
  shell. It is one syscall, safe on the main actor, and needs no permission for
  Rafu's own child.
- An agent CLI running in the shell does not change the shell's cwd, so the
  shell pid is the right pid. `CanvasTerminalBootstrap` execs the shell
  directly (`executable: shellPath`), so `shellPid` is the shell for both
  bridged and plain shells.

**Capture points.** The end of each foreground sample, and
`restorableLaunchProfile` while the restoration payload is built (window close
through `teardownTerminalGroups`, board save and close, workspace save). An
exited controller keeps its last value.

## Why it matters

- A new profile field must be stripped from named layouts. The saved-layout raw
  inspector `profileKeys = ["shell", "startingFolder"]` refuses unknown keys, so
  an unstripped field makes every named-layout save fail with
  `missingShellProfile`.
- The user-visible bug came from window close and app relaunch. Closing a board
  inside a window does not stop its shells: `stopAll` only hides the group.
- On macOS the temp directory is under `/var`, a symlink to `/private/var`. The
  normaliser resolves both the root and the candidate. Tests compare
  `standardizedFileURL.path`.

## Known limits

- Restart Shell on an exited pane uses the original start folder and still
  refuses if that folder is gone.
- The "starts in the workspace folder" label switches only after the next
  restore when a folder is deleted while the app runs.
- A `cd` in an Ensemble terminal marks the board dirty at the next
  `refreshResources`. The saved indicator is unaffected.
- A live pane after Set Pane Starting Folder records the shell's current folder
  at the next capture.

## Reproduction or evidence

- `TerminalLastWorkingFolderTests` covers normalisation, the OSC 7 host rule,
  the codec strip, and the start fallback order (updated for the root fallback).
- `TerminalWorkspaceFolderFallbackTests` and `TerminalUnsavedGroupRestorationTests`
  are new. `TerminalGroupRestorationIntegrationTests` and
  `TerminalGroupSessionIntegrationTests` are updated: "A shared Delete refresh
  detaches another window..." now expects the detached group in the payload with
  no saved layout.
- Verified (2026-11-15, Swift 6.4.2, Xcode with macOS 27.2 SDK 26B118, Darwin
  27.2.0, Mac17,13): the Terminals branch passed parallel 495 tests and 3861
  tests in 316 suites. Main gate for the Terminals merge (4fe79a0): run by the
  coordinator. No device check of the fallback or the unsaved-tab restore yet.
- Manual: user confirmed in Rafu Lightning that a shell folder is restored.

## Verification

```bash
swift test --filter TerminalLastWorkingFolderTests
./script/test.sh
./script/test.sh --no-parallel
```

## Related code, ADRs, and phases

- ADR [0023](../decisions/0023-terminal-groups-and-saved-layouts.md) (both
  2026-11-15 amendments); ADR [0004](../decisions/0004-embedded-terminal.md) cross-reference.
- Phase: [`terminal-groups.md`](../plans/phases/terminal-groups.md).
- Notes: [`terminal-signals-and-shell-catalog.md`](terminal-signals-and-shell-catalog.md),
  [`terminal-agent-identity.md`](terminal-agent-identity.md).
