# C5 — Pipelines: workflow execution, gates, runs navigator + timeline canvas

- **Branch:** `conductor/c5-pipelines` (Wave B, branch after C0 AND C1 merge)
- **Depends on:** C0 shim + C1 run engine on `main` (verify both in branch
  history before starting). Real adapters (C2–C4) are NOT required — all
  engine tests use `FakeConductorAdapter`.
- **Status:** Implemented on main (2026-07-25)
  - Commits: fc33a99 (Stage A: C1 composition seam + workflow engine + gates/retry), c5c83de (isolated EditorCanvasView routing hunk), a89309a (Stage B: runs panel, timeline canvas, gate attention, e2e fixture), c58eef1 (advisor-review defect fixes)
  - Note: coordinator-implemented directly on main after phase agent's correct stop-and-report on missing C1 seam; the conductor/c5-pipelines branch was abandoned unused
  - Verification: 0 warnings; 1479 tests parallel + serial; lint clean; staged-app GUI verify passed
  - Deferred GUI checks: panel/timeline eyeball, VoiceOver on gate verbs, second window, Reduce Motion, and real advisor(Claude)→gate→implementor(Codex) manual pipeline

## Mission

Turn single-role runs into multi-role pipelines: execute a
`.rafu/workflows/*.md` definition step by step with explicit user gates
between roles, pass artifacts forward, and give the Ensemble its real UI —
the Runs navigator panel and the editor-hosted run timeline canvas. This is
where advisor → gate → implementor → gate → documentor becomes something
you click through in Rafu with three different vendors doing the work.

## Scope

### Workflow engine (`Sources/RafuApp/Conductor/Run/`)

- `ConductorWorkflowController` composing C1's single-role controller:
  sequential steps, each step resolving its agent definition + adapter at
  start (record resolved provider/model/version in the manifest).
- **Artifact passing:** each step's prompt is assembled from the role's
  prompt body + the declared `inputArtifacts` (paths inside the run dir,
  injected by reference — the child reads files itself via `RAFU_HANDOFF`;
  do not inline megabytes into argv).
- **Gates (`gateAfter: true`):** the run parks in `awaitingGate`; user
  verbs **Approve** (next step), **Revise** (edit the artifact in a normal
  editor tab, then approve — the edited artifact is what flows forward),
  **Abort**. Steps never auto-advance past a declared gate. The final
  merge-back gate from C1 is unchanged and always present for
  `worktreeWrite` pipelines.
- **Worktree sharing:** a pipeline's mutating steps share one run worktree
  (implementor writes, documentor amends docs in the same tree);
  `readOnly` steps run per their own policy. One merge gate at the end.
- Failure semantics: a failed step parks the run (nothing downstream
  starts); retry re-runs THAT step from its input artifacts with a fresh
  step directory (attempt suffix), never mutating prior evidence.

### Runs navigator + timeline (rewrite the C0 placeholders)

- `ConductorRunsPanelView` (real): active runs with per-step status +
  gate badges, then history from `.rafu/runs`; selecting reveals the
  detail canvas; live steps expose "reveal terminal tab". Panel content
  pins to the top (the AGENTS.md `.frame(maxHeight: .infinity)`
  alignment rule — check every tab/empty state).
- `ConductorRunDetailCanvas` (real): editor-hosted standalone canvas
  (same hosting pattern as the git diff canvas): vertical step timeline —
  role name, provider/model chip, status, duration; artifacts open as
  editor tabs; diffs open in the diff canvas; gate verbs are visible
  buttons with menu/keyboard paths (no icon-only or gesture-only actions).
  State communicated by symbol + text, never color alone.
- Attention integration: a gate becoming ready raises the existing
  terminal-attention/notification pipeline (bounded text, no artifact
  content in the notification beyond the run/step name).

## Known unowned-edit hazard (flagged by the C0 review — read before starting)

`ConductorRunDetailCanvas` ships from C0 referenced by **nothing**. To host it
you must route an editor tab/standalone-canvas kind to it, which lives in
`EditorCanvasView.swift` / the editor tab-resource code — files **no conductor
phase owns** and which carried heavy user in-flight work at C0 time. Follow the
`GitStandaloneDiffCanvas` precedent (`EditorCanvasView.swift:29` branches on
`gitOpenDiff != nil && selectedDocumentID == nil`). Keep the hunk minimal and
additive, land it in ONE isolated commit, and flag it explicitly for the
integration owner — do not fold it into a larger change. If the routing needs
more than an additive branch, STOP and report.

## Owned paths

- `Sources/RafuApp/Conductor/Run/ConductorWorkflow*` (new files)
- `Views/ConductorRunsPanelView.swift`, `Views/ConductorRunDetailCanvas.swift`
  (C0 placeholders — this phase owns them now)
- The `WorkspaceSession.openConductorRun` seam body + minimal additive
  hunks for gate/reveal verbs (ONE isolated commit, flagged)
- `Tests/RafuAppTests/Conductor/Workflow*` + fixtures
- This file's status line

Forbidden: adapters, `ConductorCore.swift`, registry, Settings,
`Package.swift`, C1's single-role files beyond composing their public
surface (needed signature changes are a stop-and-report).

## Increments

1. **Workflow engine over fake adapters** — sequential execution, artifact
   flow, manifest updates; headless tests incl. fail/retry/abort.
2. **Gates** — park/approve/revise/abort semantics + tests (revise flows
   the edited artifact).
3. **Runs panel** (real) + reveal wiring.
4. **Timeline canvas** + gate verbs + attention integration; accessibility
   pass on names/roles/keyboard paths.
5. **End-to-end fixture pipeline** (3 fake roles, 2 gates, merge gate) as a
   regression test.

## Exit criteria

- The fixture pipeline runs headlessly end to end with gates honored,
  artifacts flowing (including a revised artifact), and one final merge
  gate.
- With C2 merged on `main` at integration time, the coordinator can run a
  real advisor(Claude) → gate → implementor(Codex) pipeline manually —
  listed as the post-merge GUI pass, not a branch gate.
- Deferred GUI checks listed: panel/timeline eyeball, VoiceOver on gate
  verbs, second window, Reduce Motion.

## Goal-mode prompt

> /goal Implement phase C5 exactly as scoped in
> docs/plans/phases/conductor/C5-pipelines.md. Read that file AND
> docs/plans/phases/conductor/README.md AND
> docs/decisions/0018-conductor-external-agent-orchestration.md first, in
> that order, then AGENTS.md. First run `git status --short --branch`; you
> must be on branch conductor/c5-pipelines with a clean tree, and BOTH the
> C0 shim and the C1 run engine must be present in this branch's history
> (Sources/RafuApp/Conductor/Run/ConductorRunController.swift is
> implemented, not a stub) — if not, STOP and report. Use the
> advisor→implementor→documentor workflow per increment. All engine work
> runs against FakeConductorAdapter — never a real vendor CLI. Obey the
> README worktree ground rules (headless gates only, commit on this branch,
> never push/merge, touch ONLY your owned paths; the WorkspaceSession hunks
> are minimal, additive, one isolated flagged commit). UI work follows the
> AGENTS.md interface rules: top-pinned panels, visible menu/keyboard paths
> for gate verbs, no color-only state. Finish with one consolidated report:
> per increment — changes, files, test delta, deviations, evidence; then
> the isolated shared-hunk commit id, deferred GUI checks, intended
> doc-index rows, and remaining risks.
