# C1 — Single-role runs: worktree lifecycle, PTY execution, handoff capture, diff gate

- **Branch:** `conductor/c1-single-role-runs` (Wave A, branch after C0 merges)
- **Depends on:** C0 shim on `main`
- **Status:** Merged to main (commits ac3f1ab + 7b4bba0); deferred GUI checks listed in exit criteria

## Mission

Make one agent role runnable end to end with NO real vendor CLI involved:
pick a role defined in `.rafu/agents/`, give it a task prompt, and Rafu
creates the worktree, spawns the adapter's invocation under a PTY terminal
tab, waits for the handoff artifact, persists the run, and gates the diff
for explicit user merge-back. All engine tests run against
`FakeConductorAdapter` (an echo/script adapter), so this phase is fully
parallel with the adapter phases C2–C4.

This slice is independently shippable: with C2 merged it becomes "run
Claude Code or Codex as a Rafu-managed task in a worktree, review the diff."

## Scope

### Run lifecycle (`Sources/RafuApp/Conductor/Run/`)

- `ConductorRunController` (fill the C0 stub): states
  `preparing → running → awaitingArtifact → awaitingMergeGate →
  completed | failed | aborted`, all transitions on `@MainActor`, blocking
  work off-main and cancellable.
- **Worktree policy (ADR 0018):** `worktreeWrite` roles get a Rafu-created
  worktree `rafu/run-<id>` from the user-chosen base (default: current
  HEAD) via the existing `GitService.addWorktree` path; the child's cwd is
  the worktree. `readOnly` roles run against the main checkout with the
  adapter's read-only mapping. Rafu creates worktrees — never the model.
  Cleanup uses the existing non-`--force` removal, only after the gate
  resolves, only when the worktree is clean or the user confirms discard.
- **Handoff contract:** the run directory `.rafu/runs/<id>/` and
  `RAFU_HANDOFF` env are created before spawn; completion = process exit 0
  AND the role's `handoffArtifact` file exists. Nonzero exit or missing
  artifact → `failed` with the reason in the manifest (never in Rafu logs).
  Capture stdout/stderr to `logs/` in the run dir as evidence.
- **Execution:** spawn through the C0 `TerminalProcessSpec` seam so the
  live process is a normal terminal tab (role-badged, attention pipeline
  intact). Register the pid with `ProcessResourceRegistry`. Abort =
  terminate the child, mark `aborted`, never delete user work.

### Merge gate

On `awaitingMergeGate`, surface the worktree diff through the existing
editor-hosted diff canvas (`GitOpenDiff` standalone path), scoped to the run
worktree. User verbs: **Apply to workspace** (explicit; uses existing git
plumbing, no auto-commit), **Keep worktree** (leave branch for manual
handling), **Discard** (confirmation dialog; non-force removal only when
clean or explicitly confirmed). The agent's self-report is never trusted as
the gate — the diff is.

### Launch UX (minimal in this phase)

"New Run…" from the placeholder Runs panel and the command palette: choose
agent file, enter task prompt, choose base ref, go. Run rows in the panel
show state; selecting a live run reveals its terminal tab. Full timeline UI
belongs to C5 — do not build it here.

## Owned paths

- `Sources/RafuApp/Conductor/Run/**` (fill C0 stubs, add files)
- The `WorkspaceSession` conductor seams C0 stubbed (`conductorRuns`,
  `openConductorRun`) — fill bodies only, no new stored properties without
  reporting
- Minimal additive hunks: command palette "New Run…" entry (ONE isolated
  commit, flagged for the integration owner)
- `Tests/RafuAppTests/Conductor/Run*` tests + fixtures (script-based fake
  CLI fixtures allowed; they must be offline and hermetic)
- This file's status line

Forbidden: adapters other than `FakeConductorAdapter`, `ConductorCore.swift`,
registry, Settings, `Views/Conductor*` beyond the panel's "New Run…" hook,
`Package.swift`.

## Increments

1. **Run store + lifecycle FSM** against the fake adapter, headless tests
   (happy path, nonzero exit, missing artifact, abort mid-run).
2. **Worktree integration** (create/attribute/clean up; discard
   confirmation semantics; base-ref selection) — tests over temp repos.
3. **PTY execution via the terminal seam** + attention/exit propagation.
   `swift-concurrency-pro` review path (process I/O, cancellation).
4. **Merge gate** (diff canvas scope, apply/keep/discard) + AGENTS.md
   security review (write path, worktree removal).
5. **Launch UX + persistence polish** (runs reload from `.rafu/runs` on
   workspace open; live terminals are never restored — ADR 0004/0014).

## Exit criteria

- A scripted fake role runs end to end headlessly: worktree created, PTY
  process runs, artifact captured, manifest persisted, diff gate resolves
  all three verbs correctly, worktree cleaned up.
- Zero regressions in existing terminal and git test suites.
- Deferred to post-merge GUI pass (list in report): live terminal tab
  badge, attention notification on completion, diff canvas eyeball, second
  window.

## Goal-mode prompt

> /goal Implement phase C1 exactly as scoped in
> docs/plans/phases/conductor/C1-single-role-runs.md. Read that file AND
> docs/plans/phases/conductor/README.md AND
> docs/decisions/0018-conductor-external-agent-orchestration.md first, in
> that order, then AGENTS.md. First run `git status --short --branch`; you
> must be on branch conductor/c1-single-role-runs with a clean tree and the
> C0 shim present (Sources/RafuApp/Conductor/ConductorCore.swift exists) —
> if not, STOP and report. Use the advisor→implementor→documentor workflow
> per increment. Obey the README worktree ground rules: headless gates only
> (swift build 0 warnings; swift test AND swift test --no-parallel;
> ./script/format.sh --fix then --lint), commit on this branch in verified
> stages, never push/merge, touch ONLY your owned paths — all engine work
> runs against FakeConductorAdapter, never a real vendor CLI. Security
> invariants: argv arrays only, minimal env, no prompt/artifact/output text
> in Rafu logs, ProcessResourceRegistry registration, never `git worktree
> remove --force`, no @unchecked Sendable. Finish with one consolidated
> report: per increment — changes, files, test delta, deviations, evidence;
> then the isolated command-palette commit id, deferred GUI checks,
> intended doc-index rows, and remaining risks.
