# Ensemble run-state observability: terminal transitions must stamp step status

- Applies to: `Sources/RafuApp/Conductor/Run/ConductorWorkflowController.swift`, `ConductorRunController.swift`, `ConductorEnsembleEventCenter`, `ConductorEnsembleStateProjection`, `Sources/RafuCore/Ensemble/EnsembleCommandRunner.swift`
- Last verified: Swift 6.2 / macOS 26 / 2026-07-26 (phase C8-04)

## Rule or observed behavior

`ConductorEnsembleEventCenter.runChanged(manifest:)` (`ConductorEnsembleEventCenter.swift:73`) hard-codes `liveState: nil` (line 82). So for any manifest-only event, `ConductorEnsembleStateProjection.runState` can derive the run state **only from step status**. A transition to a terminal state that leaves steps `.pending` publishes an event that projects as `.pending` — invisible to a coordinator's `rafu ensemble await` or `status`, which then blocks until its deadline.

**Rule:** any transition to a terminal state must stamp the status of every affected step, not merely set the controller state or clear the gate.

This is not recoverable after the fact: `await` consumes only events emitted *after* its initial snapshot (`EnsembleCommandRunner.swift` ~405–427), so a missed or mis-projected event cannot be repaired by re-reading.

## Why it matters

Three separate defects in one phase shared this single root cause — all found in review *after* the feature worked end to end:

1. `declinePlanGate` (`ConductorWorkflowController.swift:1188`) — terminated the run but left the parked steps `.pending`.
2. `abort()` → `markAborted()` (`ConductorWorkflowController.swift:1477`) from `.awaitingPlanGate` — same shape: controller state changed, steps untouched. `activeStepIndex` returns `nil` for that state, so its existing single-step stamp never fired.
3. Restart recovery of a parked plan gate — fixed with `Disposition.abandonedAtPlanGate` (`ConductorRunRecovery.swift:37`), which stamps every step rather than only clearing the gate.

Each presents identically to a coordinator: the verb returns success, the run is finished in the UI, and the coordinator hangs until timeout. The failure is silent on the producer side, which is why it recurred three times before being classified.

## Reproduction or evidence

Start a run with `--plan-gate`, then from a second process:

1. `rafu ensemble await <run> --state aborted`
2. Decline the plan gate in the UI (or `rafu ensemble abort <run>`).

Before the fix, `await` never completes and exits on its deadline; the projected state stays `.pending` because the published manifest's steps were never stamped. After stamping every affected step's status, the same event projects terminal and `await` returns immediately.

## Verification

- `./script/build.sh` — exit 0, zero warnings.
- `./script/test.sh` — 1683 tests, 81 suites, 0 issues (76s).
- `./script/test.sh --no-parallel` — 1683 tests, 81 suites, 0 issues (206s).
- `./script/format.sh --fix` then `--lint` — both exit 0.

## Related code, ADRs, and phases

- [`conductor-pipeline-engine.md`](conductor-pipeline-engine.md) — plan-gate FSM and gate distinction
- [`ensemble-ipc-verbs.md`](ensemble-ipc-verbs.md) — run-state projection and streaming events
- [`../plans/phases/conductor/C8-04-plan-gate-and-propose-merge.md`](../plans/phases/conductor/C8-04-plan-gate-and-propose-merge.md)
- [ADR 0018](../decisions/0018-conductor-external-agent-orchestration.md)
