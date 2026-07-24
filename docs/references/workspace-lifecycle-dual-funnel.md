# Workspace lifecycle: dual-funnel opening logic (initial open vs. restore)

- Applies to: `Sources/RafuApp/Models/WorkspaceSession.swift` (`openLocalWorkspace`, `restoreLastWorkspaceIfAvailable`, and any work that must fire when a workspace root is acquired)
- Last verified: Swift 6.2 / macOS 26 / 2026-07-25 (phase C1)

## Rule or observed behavior

A `WorkspaceSession` acquires a workspace root through TWO separate code paths, and they do not call each other:

1. **`openLocalWorkspace(at:)`** (line 993): called when the user explicitly opens a folder (file importer, Finder drag-drop, CLI), or when a window is replaced with a different workspace. Performs git discovery, recent-workspace recording, file-watcher setup, language-intelligence notifications, and workspace-state persistence.

2. **`restoreLastWorkspaceIfAvailable()`** (line 3634): called when restoring a window's last session. Loads the restored `RestorableWorkspace` from disk, validates security-scoped URLs, re-hydrates the file tree and editor state, and performs the SAME language-intelligence and file-watcher setup — but skips `openLocalWorkspace` entirely.

Any work that must run when a window gains a workspace root (examples: reloading persisted Conductor runs, priming a cache, refreshing external state) needs to be called from **both** functions.

## Why it matters

It is easy to assume "when a workspace opens" means calling a helper function from `openLocalWorkspace`, and restoration is "automatic" — but restoration does not call `openLocalWorkspace`. The two paths diverge early:

- `openLocalWorkspace` handles a NEW or REPLACED workspace: the user deliberately chose it.
- `restoreLastWorkspaceIfAvailable` handles window STATE RESTORATION: the workspace root is recovered from `RestorableWorkspace` on disk and re-established without user action.

Missing the restore path means:

- Workspaces that restore from a previous session lose workspace-specific state (e.g., Conductor runs list is empty on window restore, even though `.rafu/runs/` exists on disk).
- The inconsistency persists until the user explicitly opens the same workspace again or focuses a different window and restores it.
- A feature that worked on initial open but failed silently on restore is hard to diagnose because the two code paths are far apart and easy to overlook.

## Reproduction or evidence

`WorkspaceSession.reloadConductorRuns(for:)` (line 1049) is called from both paths:

- Line 1034: `openLocalWorkspace(at:)` calls `reloadConductorRuns(for: url)` after setting up watchers and recording recent workspaces.
- Line 3659: `restoreLastWorkspaceIfAvailable()` calls `reloadConductorRuns(for: resolved.url)` after hydrating the editor state and notifying language intelligence.

Comment at line 1044–1048 explicitly notes: "Called from both `openLocalWorkspace(at:)` and `restoreLastWorkspaceIfAvailable()`, the two funnels that give a window a new workspace root."

Verification (manual or automated): open a workspace with Conductor runs, close the window, relaunch the app. The runs list populates on window restore, not just after explicit open.

## Related code, ADRs, and phases

- `Sources/RafuApp/Models/WorkspaceSession.swift`:
  - `openLocalWorkspace` (line 993–1037)
  - `restoreLastWorkspaceIfAvailable` (line 3634–3675)
  - `reloadConductorRuns` (line 1049–1051)
  - `RestorableWorkspace` model (line 11–54)
- `Sources/RafuApp/Conductor/Run/ConductorRunController.swift` — the `attachAndReload` method
- [`../plans/phases/conductor/C1-single-role-runs.md`](../plans/phases/conductor/C1-single-role-runs.md) — C1 eager reload requirement (lines 202–206)
