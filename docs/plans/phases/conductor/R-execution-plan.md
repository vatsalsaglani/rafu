# R-series — remediation fan-out plan (from the 2026-07-29 manual test)

- **Status:** Ready to run (2026-07-29). Derives from
  [`ensemble-2026-07-29-remediation.md`](ensemble-2026-07-29-remediation.md)
  (findings F1–F6). Read that document first; each plan below assumes it.
- **Mode:** one goal-mode agent per worktree, run directly (no
  advisor/implementor subagents). Each plan document contains the goal prompt
  to start its agent.

## Plans, branches, waves

| Plan | Branch | Wave | Fixes | Depends on |
|---|---|---|---|---|
| [`R1-readonly-handoff-contract.md`](R1-readonly-handoff-contract.md) | `conductor/r1-readonly-handoff` | 1 | F1 (Claude + contract + fail-closed seam) | none |
| [`R2-run-terminal-rendering.md`](R2-run-terminal-rendering.md) | `conductor/r2-run-terminal-rendering` | 1 | F2 | none |
| [`R3-file-tree-freshness.md`](R3-file-tree-freshness.md) | `conductor/r3-file-tree-freshness` | 1 | F3 | none |
| [`R4-run-evidence-and-activity.md`](R4-run-evidence-and-activity.md) | `conductor/r4-run-evidence-activity` | 1 | F5 + F4 | none |
| [`R5-adapter-readonly-probes.md`](R5-adapter-readonly-probes.md) | `conductor/r5-adapter-readonly-probes` | 2 | F1 (Codex, OpenCode, Cline) | R1 merged |
| [`R6-single-role-overrides.md`](R6-single-role-overrides.md) | `conductor/r6-single-role-overrides` | 2 | F6 | R1 merged (launcher surface) |

Wave 1 runs four worktrees in parallel; their owned paths are disjoint (table
below). Wave 2 branches only after every wave-1 branch has merged to `main`
and the coordinator has re-run `script/build.sh` + both test modes there.

## Starting a worktree

From the primary checkout (replace the branch per plan):

```bash
git worktree add .claude/worktrees/conductor+r1-readonly-handoff \
  -b conductor/r1-readonly-handoff main
cd .claude/worktrees/conductor+r1-readonly-handoff
```

Then start a goal-mode agent in that directory with the plan's **Goal prompt**
block, verbatim.

## Shared-file collision rules

| Path | Owner | Everyone else |
|---|---|---|
| `Sources/RafuApp/Conductor/Adapters/*` | R1 (wave 1), R5 (wave 2) | do not touch |
| `Sources/RafuApp/Conductor/ConductorCore.swift` | R1 | do not touch — stop and report if a change seems needed |
| `Sources/RafuApp/Conductor/Run/WorkspaceConductorRunLauncher.swift` | R1 | do not touch |
| `Sources/RafuApp/Conductor/Run/ConductorRunOutputCapture.swift` + new formatter files | R2 | do not touch |
| Terminal hosting view (Restart Shell overlay seam) | R2 | do not touch |
| `Sources/RafuApp/Models/WorkspaceSession.swift` (FS-monitor region only) | R3 | do not touch |
| File tree node/sidebar sources | R3 | do not touch |
| `ConductorRunController.swift`, `ConductorRunStore.swift`, `ConductorRunRecovery.swift` | R4 | do not touch |
| `Sources/RafuApp/Views/ConductorRunsPanelView.swift` (Activity section) | R4 | do not touch |
| `Sources/RafuApp/Conductor/Run/ConductorNewRunModel.swift` + New Run canvas view | R6 | do not touch |
| `docs/references/conductor-cli-capability-matrix.md` | R1 (wave 1), R5 (wave 2) | do not touch |
| `docs/plans/phases/conductor/ensemble-manual-test-plan.md` | R1 only (append-only) | do not touch |
| `Package.swift`, `AGENTS.md`, shared indexes | nobody | coordinator only |

New test files: each plan creates its own uniquely named files under
`Tests/RafuAppTests/Conductor/`; never edit a test file another plan or an
integration handoff owns — a failure there is stop-and-report.

## Standing rules baked into every goal prompt

1. Read `AGENTS.md`, the remediation document, and your plan before editing.
2. `script/build.sh` / `script/test.sh` only; one SwiftPM invocation at a
   time; never poll; background long runs and wait for the notification.
3. Final sequence, in order, nothing touching files afterwards:
   format fix → format lint → build → **parallel** tests → commit.
4. `rm -rf .build` as the very last step, after commits, never to "fix" a
   failing build.
5. No push, no PR, no merges — the coordinator merges.
6. Standing learning rule: probe results and durable nuances land in
   `docs/references/` (or the capability matrix) in the same change.

## Exit gate for the whole series

Re-run manual test plan sections C and D through D7 in the
`ensemble-test` repository: C1 shows a readable working terminal, C3
completes (not fails), C5 opens a real `brief.md`, C6's evidence is visible
in the file tree, and the Activity feed identifies its runs.
