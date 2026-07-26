# Ensemble pipeline engine: workflow execution, gates, and multi-role orchestration

- Applies to: `Sources/RafuApp/Conductor/Run/ConductorWorkflowController.swift` (C5 pipeline engine) and related UI views (`ConductorRunsPanelView`, `ConductorRunDetailCanvas`), plus Views/WorkspaceSession seams that route run details to the canvas
- Last verified: Swift 6.2 / macOS 26 / 2026-07-25 (phase C5);
  corrected 2026-07-26 against `ConductorRunEvidenceLayout`;
  extended 2026-07-26 (C8-04) with the plan-gate FSM

## Rule or observed behavior

### Peer engine, not a wrapper

`ConductorWorkflowController` is a **peer orchestrator** for multi-step workflows, not a wrapper around `ConductorRunController`. It owns:

- Sequential step invocation with per-step adapter resolution (each step resolves its agent definition and adapter at start time, recording provider/model/version in the manifest).
- All manifest writes go through a **single published queue** via `ConductorRunController.publish(...)` — the one serialized entry point for peer engines speaking to the same run directory. This prevents concurrent writes that would corrupt or lose evidence.
- Pure step spec building and launch via `ConductorRoleLaunchService`, with no internal state machine — the controller itself drives the state through sequential async calls.

### One workflow plan per run; mixed autonomy semantics

A workflow's `.rafu/workflows/*.md` definition produces ONE run-level `worktreeWrite` decision (if ANY step needs it), even though individual steps carry `readOnly` autonomy. The implementation:

- `readOnly` steps execute in the shared worktree under their adapter's read-only sandbox mapping (the adapter ensures no writes).
- Mutating steps write to the same shared worktree.
- The final merge gate is always present for `worktreeWrite` pipelines (deliberate duplication of merge-gate verb guards — NOT unified; coordinator decision to keep gate logic localized per engine).

### Evidence layout and attempt immutability

Step evidence lives under `.rafu/runs/<id>/steps/<NN>-<slug>-a<N>/` where:

- `<NN>` is the 2-digit, 1-based on-disk step number (e.g., `01`, `02`).
- `<slug>` is the sanitized agent name (lowercase alphanumeric + hyphens only; slug sanitizer rejects uppercase and special characters; see `conductor-file-contracts.md` for exact rules).
- `<a<N>>` is the **attempt suffix**: `-a1` for first execution, `-a2` for first retry, etc.

**Immutability rule:** retry never mutates prior evidence. The `prepare()` phase throws if an attempt directory exists, forcing each retry into a fresh attempt-numbered directory. Logs, prompts, and handoff artifacts from failed or revised steps remain intact for review.

### Artifact passing by reference and the Revise semantics

Each step's prompt is assembled by composing:
- The role's prompt body (from `.rafu/agents/<name>.md`).
- **Artifact inputs** declared as `<- artifact1, artifact2` in the workflow.

Prompts embed **absolute paths** to earlier steps' handoff artifacts. When a child launches, it:
1. Receives `RAFU_HANDOFF` pointing to its own output directory.
2. Re-reads input artifacts from disk using absolute paths provided in the prompt.

This enables the **Revise flow:**
1. User edits a step's artifact in a normal Rafu editor tab.
2. Clicks "Approve" without saving the buffer.
3. The implementor's next run re-reads the stale on-disk artifact, not the unsaved buffer.

**Known caveat:** an unsaved editor buffer is not what the child reads. This is intentional — Rafu does not auto-save editor buffers. If the user means to use a revision, they must save it first.

### Gate semantics: awaitingGate vs. awaitingMergeGate

- **`awaitingGate`** parks the run while awaiting a user verb (Approve/Revise/Abort) on a step whose workflow definition declares `[gate]`.
- **`awaitingMergeGate`** parks the run before the final merge-back into the workee's tree (only for `worktreeWrite` pipelines; always present).

These are distinct states with different semantics:
- A step gate is opted in per-step in the workflow definition.
- The merge gate is part of the orchestration contract, not the workflow.

### Approving gates: reentrancy and generation bumping

The `approveGate` verb is reentrant under concurrent predicates. To prevent the same approval from completing multiple times:

1. **Mint a generation stamp** before any state transition (while still on the original actor).
2. **Transition state immediately** (still synchronously on the actor before the first `await`).
3. Use the generation stamp to guard all downstream work — even though the verb is now reachable due to state change, a stale approval (same generation) is ignored.

**Why this matters:** menu and palette predicates key on the same FSM state. If you transition state AFTER an await, a concurrent menu item may read the old state, call the same verb, and win the race after your first call resumed. The fix is to move state synchronously before any suspension point, and to mint a generation guard that covers the entire verb.

### Retry context validation: validate before mutate/publish

When retrying a failed step:

1. **Validate** the input context (prior step existence, artifact paths, etc.) BEFORE any publish or directory mutation.
2. Only after validation succeeds, call `publish(retry(...))` to record the retry attempt and create the fresh attempt directory.

Validating first avoids half-applied retries where some state is recorded but artifact prep fails partway through.

### Presentation precedence and panel ordering

The `ConductorRunsPanelView` displays active runs first, then history, ordered by semantic status precedence:

```
failed > aborted > awaitingGate > running > pending > completed
```

This precedence (failed highest, completed lowest) ensures the user's immediate attention goes to broken runs, then awaiting-gate, then in-progress work. **This is NOT chronological order.**

A step with status `failed` always floats to the top of the active runs section, even if newer runs are still pending. A gate-awaiting run displays higher than a completing run that started earlier.

### Plan-gate FSM (C8-04)

`run --plan-gate` adds one more parked state, `awaitingPlanGate`, ahead of
every step. It is in-flight (`isInFlight` returns `true`) but has no "current
step" the way `.runningStep`/`.awaitingGate` do — `activeStepIndex(in:)`'s
`default: nil` arm covers it.

| Verb | From | To | Notes |
|---|---|---|---|
| `start(_:launcher:)` with `planGateRequested` | `.idle`/terminal | `.awaitingPlanGate` | Publishes the manifest with `gate: .plan` and every step `.pending`, fires `onGateReady(kind: .plan, safeToApproveRemotely: false)`, and RETURNS before `worktreeService.materialize` or any `launcher.launch` call |
| `approvePlanGate()` (re-parse succeeds) | `.awaitingPlanGate` | `.preparing` → `.runningStep(0)` | Rebuilds the manifest from the FRESH parse, materializes, launches step 0 |
| `approvePlanGate()` (re-parse fails) | `.awaitingPlanGate` | `.awaitingPlanGate` | `planGateIssue` is set to the failure text; the park is otherwise untouched |
| `declinePlanGate(note:)` | `.awaitingPlanGate` | `.aborted` | `recoveryNote` bounded to 1000 characters; every step is marked `.aborted`, even though nothing ran |
| `abort()` | `.awaitingPlanGate` | `.aborted` | Same generic abort path every other in-flight state uses |
| `approveGate()` | `.awaitingPlanGate` | forwards to `approvePlanGate()` | One user-facing "Approve" verb; no separate menu/command entry needed |

**What has actually run behind a plan gate (advisor A1).** "Nothing spawns"
does not mean nothing executed: the SAME validation a normal `start()` runs
(`prepare(_:generation:store:)`, shared by both paths) still runs read-only
`git` probes (`GitService.snapshot`, `worktreeService.plan(...)` — which only
COMPUTES the intended worktree path and confirms it does not already exist,
never creates it) and each step's adapter-version probe (e.g. `<cli>
--version`) before parking. What genuinely does NOT happen: `worktreeService
.materialize(_:)` (no worktree directory, no branch), and `launcher.launch(
_:onExit:)` (no agent process, no evidence directory). A zero-spawn test
asserts BOTH `launcher.recorded.isEmpty` and that `controller.plan?
.worktreeURL` does not exist on disk.

**The approve-time re-parse rule (advisor A2/A3).** `approvePlanGate()` never
trusts the parked `ConductorWorkflowRunRequest`'s `workflow`/`roles` as truth
— it re-loads and re-parses `.rafu/workflows`/`.rafu/agents` at THE MOMENT OF
APPROVAL (D2: files are the source of truth, and the human may have hand-
edited them while the run sat parked). Two re-parse paths share one contract
(`ConductorPlanGateReparseOutcome`):

- **Built-in** (`builtInPlanGateReparse(for:)`) — used whenever `controller
  .planGateReparse` is `nil`: every UI-started run and most unit tests.
  Re-locates the workflow by NAME (stem-or-declared-name, mirroring
  `ConductorEnsembleRequestService.startRun`'s own lookup) and rebuilds roles
  via `ConductorWorkflowBinder`. It does not reapply `--role`/`--artifact`
  overrides — it has no originating payload to read them from.
- **Installed** — `ConductorEnsembleRequestService.startRun` installs a
  closure on every controller it creates, right after `dependencies
  .startRun` returns, that calls the SAME `resolveRunDefinitions(payload:
  workspace:)` method `startRun` itself used, against the SAME captured
  `payload`/`workspace`. This is the one and only implementation of "apply
  `--role` overrides and the `--artifact` input-reference appendix" — a
  second, drifting implementation at approve time would silently drop a
  coordinator's overrides on every plan-gated run, which is a correctness
  bug, not an acceptable simplification.

A re-parse `.failure(String)` NEVER falls back to the stale parked parse: the
run stays `.awaitingPlanGate`, and `planGateIssue` carries the exact reason
(a missing/invalid workflow file, an unknown agent, a malformed provider) so
the UI can show it next to Approve Plan.

**Manifest rebuild, not mutation (advisor A3).** `ConductorRunManifest
.workflowName`/`baseCommit`/`worktreeBranch` are `let` — a hand-edit at the
gate may add a step, remove one, or flip a role's autonomy (changing
`anyWorktreeWrite` and therefore the whole `ConductorWorkspacePlan`), so
`approvePlanGate()` on success constructs a BRAND NEW `ConductorRunManifest`
value: same `id`/`createdAt`/`startedBy`/`label`, but `workflowName`/
`baseCommit`/`worktreeBranch`/`steps` all come from the fresh
`prepare(_:generation:store:)` result. Same run id ⇒ same on-disk file, one
write — never two manifests for one run.

**Decline must mark every step `.aborted`, not leave them `.pending`.** This
corrects the phase's original design brief, which specified leaving every
step `.pending` on decline (mirroring `markAborted()`'s handling of a
sibling step). That does not work: `ConductorEnsembleEventCenter
.runChanged(manifest:)` — the seam every `publish(_:)` call routes through —
derives `EnsembleRunState` from `ConductorEnsembleStateProjection.runState`
with `liveState: nil`; it has no parameter carrying the controller's actual
in-memory FSM state at publish time. That projection can ONLY read
`.aborted` from a manifest that has no open gate and NO steps still
`.pending` if at least one step's OWN `status` is `.aborted` — a manifest
with an untouched `.pending` step (and no gate) projects as `.pending`
forever. Since a plan gate has no "active step" to mark the way an
in-progress abort does (`activeStepIndex(in: .awaitingPlanGate)` is `nil`),
`declinePlanGate(note:)` marks EVERY step `.aborted` instead — accurate,
since none of them will ever run — so the decline is actually observable via
`status`/events rather than looking identical to a plan gate that was simply
never approved yet.

**A5: `appliedButCleanupFailed` still stamps `mergedAt`.** Both controllers'
`applyToWorkspace()` treat a successful `mergeGateService.apply` followed by
a cosmetic worktree-cleanup failure the same as a clean success for the
purpose of `mergedAt`: the Git-visible merge-back into the user's workspace
already happened, so `mergedAt` is stamped and the run completes either way.
Not stamping would hang a coordinator's `await --state merged` forever on a
cleanup failure that has nothing to do with whether the merge itself
succeeded. `mergeGateError` is still surfaced separately so the human sees
the cleanup problem.

## Why it matters

1. **Peer engine distinction** clarifies that the pipeline engine is not subordinate to C1's single-role controller, and that all manifest writes are serialized for correctness.
2. **One plan per run** simplifies the merge-gate logic and guarantees a single decision point for the worktree.
3. **Immutability rule** preserves evidence for review, debugging, and audit without risk of overwrite.
4. **Artifact by reference** makes Revise work without copying; the unsaved-buffer caveat is a documented constraint, not a bug.
5. **Gate distinction** prevents confusion between step-level gates and the merge gate.
6. **Generation guards** prevent reentrancy-related double-completion under concurrent UI predicates.
7. **Validation-before-mutate** prevents half-applied retries.
8. **Presentation precedence** makes the UI actionable — failures and gates stay visible at the top.

## Reproduction or evidence

- C5 implementation: four commits (fc33a99, c5c83de, a89309a, c58eef1) on `main` (2026-07-25).
- Workflow engine tested end-to-end with a 3-step fake-adapter fixture (C5-pipelines increment 5): sequential execution, gates honored, artifacts flowing (including a revised artifact), merge gate executed.
- All engine work runs against `FakeConductorAdapter` with no real CLI invocations.
- `swift test` and `swift test --no-parallel` pass 1479 tests (parallel + serial) with 0 warnings; `./script/format.sh --lint` clean; staged-app GUI verify passed.

## Verification

```bash
# C5 commits on main (2026-07-25)
git log --oneline --graph -5 main | grep -E "fc33a99|c5c83de|a89309a|c58eef1"

# Run the full test suite
swift test
swift test --no-parallel

# Lint
./script/format.sh --lint

# Launch and verify GUI (post-merge on main only)
./script/build_and_run.sh --verify
```

Test files:
- `Tests/RafuAppTests/Conductor/WorkflowEngineTests.swift` — fixture pipeline, step sequencing, gates, retries
- `Tests/RafuAppTests/Conductor/RunDetailCanvasTests.swift` — presentation state and gate routing

## Related code, ADRs, and phases

- `Sources/RafuApp/Conductor/Run/ConductorWorkflowController.swift` (peer engine, step sequencing, gate semantics)
- `Sources/RafuApp/Conductor/Run/ConductorRoleLaunchService.swift` (role launch service shared with C1's single-role controller)
- `Views/ConductorRunsPanelView.swift`, `Views/ConductorRunDetailCanvas.swift` (UI for active/history runs, step timeline, gate verbs)
- [`conductor-file-contracts.md`](conductor-file-contracts.md) — pipeline directory layout, slug sanitizer, optional manifest fields
- [`conductor-pty-spawn-and-child-environment.md`](conductor-pty-spawn-and-child-environment.md) — process invocation and child environment
- [`../decisions/0018-conductor-external-agent-orchestration.md`](../decisions/0018-conductor-external-agent-orchestration.md) — orchestration design and non-goals
- [`../plans/phases/conductor/C5-pipelines.md`](../plans/phases/conductor/C5-pipelines.md) — phase scope and exit criteria
