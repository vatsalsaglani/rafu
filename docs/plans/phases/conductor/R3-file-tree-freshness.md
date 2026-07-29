# R3 — the file tree must show directories created after first load (F3)

- **Branch:** `conductor/r3-file-tree-freshness` · **Wave:** 1 · **Depends:** none
- **Fixes:** finding F3 of
  [`ensemble-2026-07-29-remediation.md`](ensemble-2026-07-29-remediation.md).

## Problem

During the manual test, `.rafu/runs/` existed on disk (two run directories,
manifests, logs) while the sidebar tree showed only `.rafu/agents` and
`.rafu/workflows`. The user concluded no runs were recorded. `.rafu` itself
renders, so dotfiles are not hidden wholesale. Manual-plan check C6 ("check
`.rafu/runs/<id>/` in the file tree") is impossible until this is fixed.

## Deliverables

1. **Diagnosis first, in the report:** determine which of the two candidate
   causes is real — (a) directory children are loaded once on first
   expansion and the filesystem monitor does not refresh nested directories
   created later; (b) an ignore filter excludes the path. Inspect
   `WorkspaceFileNode` loading and the filesystem monitor owned by
   `WorkspaceSession` (DispatchSource/FSEvents usage).
2. Fix so that an expanded directory reflects children created afterwards,
   within a bounded refresh (no polling loops; use the existing FS-event
   machinery, widened or re-scoped as needed). Lazy loading for collapsed
   directories stays — do not preload the world; the memory budget stands.
3. Tests where the seams allow (node-refresh unit tests); otherwise a
   documented manual verification: start a run, watch `.rafu/runs/<id>/`
   appear without collapsing/reopening.

## Owned paths

The file tree node/model sources (`WorkspaceFileNode` and friends),
`Sources/RafuApp/Views/WorkspaceSidebarView.swift`, and the FS-monitor region
of `Sources/RafuApp/Models/WorkspaceSession.swift` only. No other
WorkspaceSession region — that file is historically contested; keep the diff
surgical.

## Goal prompt (paste verbatim into a goal-mode agent in this worktree)

```
Read AGENTS.md, docs/plans/phases/conductor/ensemble-2026-07-29-remediation.md
(finding F3), and docs/plans/phases/conductor/R3-file-tree-freshness.md. You
are on branch conductor/r3-file-tree-freshness in a dedicated worktree; obey
the plan's owned paths and R-execution-plan.md's collision table. In
WorkspaceSession.swift touch only the filesystem-monitor region; keep the
diff surgical.

Goal: a directory created inside an already-expanded tree directory must
appear in the sidebar without the user collapsing or reopening anything.
Reproduction: .rafu/runs/ is created by the first Ensemble run after .rafu
was already expanded; it never appears.

First diagnose which cause is real: (a) children loaded once on first
expansion with no nested-directory refresh from the filesystem monitor, or
(b) an ignore filter. State the diagnosis with evidence in your report. Then
fix it using the existing FS-event machinery — no polling loops, no timers,
no preloading of collapsed directories (lazy loading and the idle-memory
budget stand; AGENTS.md forbids wait loops).

Add node-refresh unit tests where seams allow. GUI verification: use
./script/build_and_run.sh, create a nested directory under an expanded
folder from a terminal, and confirm it appears; describe exact manual steps
in your report for the user to repeat (do not drive the GUI with synthetic
input).

Rules: script/build.sh and script/test.sh only, one SwiftPM invocation at a
time, never poll, background long runs. Finish with format fix → format lint
→ build → parallel tests → commit; nothing may modify files after the
parallel run. Then rm -rf .build. Do not push. Report: diagnosis, delivered
behavior, changed paths, test results, remaining risks.
```

## Acceptance

Start an Ensemble run with `.rafu` expanded: `.rafu/runs/<id>/` appears live.
A second workspace window's tree stays independent. No new polling anywhere.
