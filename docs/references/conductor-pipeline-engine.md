# Ensemble pipeline engine: workflow execution, gates, and multi-role orchestration

- Applies to: `Sources/RafuApp/Conductor/Run/ConductorWorkflowController.swift` (C5 pipeline engine) and related UI views (`ConductorRunsPanelView`, `ConductorRunDetailCanvas`), plus Views/WorkspaceSession seams that route run details to the canvas
- Last verified: Swift 6.2 / macOS 26 / 2026-07-25 (phase C5);
  corrected 2026-07-26 against `ConductorRunEvidenceLayout`

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
