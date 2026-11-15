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
then the existing refusal. Rafu does not substitute the workspace root (ADR 0023
forbids substitution).

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

- Unsaved Terminal Group tabs are not restored (this was already so).
- Restart Shell on an exited pane uses the original start folder.
- A `cd` in an Ensemble terminal marks the board dirty at the next
  `refreshResources`. The saved indicator is unaffected.
- A live pane after Set Pane Starting Folder records the shell's current folder
  at the next capture.

## Reproduction or evidence

- `TerminalLastWorkingFolderTests` covers normalisation, the OSC 7 host rule,
  the codec strip, and the start fallback order.
- Manual: user confirmed in Rafu Lightning that a shell folder is restored.

## Verification

```bash
swift test --filter TerminalLastWorkingFolderTests
./script/test.sh
./script/test.sh --no-parallel
```

## Related code, ADRs, and phases

- ADR [0023](../decisions/0023-terminal-groups-and-saved-layouts.md) (2026-11-15
  amendment); ADR [0004](../decisions/0004-embedded-terminal.md) cross-reference.
- Phase: [`terminal-groups.md`](../plans/phases/terminal-groups.md).
- Notes: [`terminal-signals-and-shell-catalog.md`](terminal-signals-and-shell-catalog.md),
  [`terminal-agent-identity.md`](terminal-agent-identity.md).
