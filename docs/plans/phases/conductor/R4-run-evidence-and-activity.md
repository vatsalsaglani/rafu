# R4 — no manifest-less run directories, and an Activity feed that names its run (F5 + F4)

- **Branch:** `conductor/r4-run-evidence-activity` · **Wave:** 1 · **Depends:** none
- **Fixes:** findings F5 and F4 of
  [`ensemble-2026-07-29-remediation.md`](ensemble-2026-07-29-remediation.md).

## Problems

**F5 — orphan evidence.** Run `4947e871…` in the user's test repo has
`prompt.md` and `handoff/` but no `manifest.json` and no logs. Loading skips
manifest-less directories silently, so no surface can ever show that run —
contradicting the recovery contract (manual plan G8: degraded runs surface
with an explicit note, never vanish).

**F4 — activity ambiguity.** The Activity feed showed one run's transitions
(Pending → Running → Interrupted) as three visually identical rows, each
with its own Open Run button — read by the user as "the same run repeated 3
times." Separately, the run's manifest ends `failed`, yet the newest event
said `Interrupted`; either that event belongs to the orphan run or a failed
completion is mislabelled. A failed run must read Failed, never Interrupted.

## Deliverables

1. The initial manifest is written **atomically at run creation, before any
   process spawns**. A run directory must never exist without a manifest.
2. Recovery/listing surfaces a manifest-less run directory as degraded
   history ("evidence present, manifest missing") instead of skipping it.
3. Activity rows carry run identity: a short run identifier (or per-run
   grouping of consecutive events) so three transitions of one run cannot
   read as three runs. Keep the feed's event-per-transition model (manual
   plan K5) — this is labeling/grouping, not a redesign.
4. Investigate and fix the Interrupted-vs-failed mismatch: reconstruct which
   run emitted the Interrupted event; ensure a run that completes failed
   emits a Failed event.
5. Regression tests for all four: creation-time manifest, degraded-history
   surfacing, activity labeling, failed-event emission.

## Owned paths

`Sources/RafuApp/Conductor/Run/ConductorRunController.swift`,
`Sources/RafuApp/Conductor/ConductorRunStore.swift`,
`Sources/RafuApp/Conductor/Run/ConductorRunRecovery.swift`, the Activity
section of `Sources/RafuApp/Views/ConductorRunsPanelView.swift` and its event
source, new tests
`Tests/RafuAppTests/Conductor/RunEvidenceAndActivityTests.swift`.
`ConductorCore.swift` is owned by R1 — if the manifest model itself needs a
change, stop and report to the coordinator instead of editing it.

## Goal prompt (paste verbatim into a goal-mode agent in this worktree)

```
Read AGENTS.md, docs/plans/phases/conductor/ensemble-2026-07-29-remediation.md
(findings F4 and F5), and
docs/plans/phases/conductor/R4-run-evidence-and-activity.md. You are on
branch conductor/r4-run-evidence-activity in a dedicated worktree; obey the
plan's owned paths and R-execution-plan.md's collision table. ConductorCore.swift
belongs to another worktree — if the manifest model must change, stop and
report instead of editing it.

Goal, four parts:
1. Write the initial run manifest atomically at run creation, BEFORE spawning
   any process, so a run directory can never exist without a manifest.
   Evidence of the bug: a real run directory with prompt.md and handoff/ but
   no manifest.json, invisible to every surface.
2. Make recovery and listing surface a manifest-less run directory as
   degraded history with an explicit "evidence present, manifest missing"
   note — never skip it silently (matches manual plan G8's contract).
3. Give Activity feed rows run identity — a short run id chip or per-run
   grouping — so one run's Pending/Running/Interrupted transitions cannot
   read as three separate runs. Keep the event-feed model from manual plan
   K5; every status keeps symbol plus text, never color alone.
4. Reconstruct why the newest Activity event said Interrupted while the
   run's manifest ended failed; fix so a failed completion emits a Failed
   event. State what you found in your report.

Add regression tests in
Tests/RafuAppTests/Conductor/RunEvidenceAndActivityTests.swift using the
FakeConductorAdapter patterns already in the suite. Do not edit test files
owned by other plans or integration handoffs — a failure there is
stop-and-report.

Rules: script/build.sh and script/test.sh only, one SwiftPM invocation at a
time, never poll, background long runs. Finish with format fix → format lint
→ build → parallel tests → commit; nothing may modify files after the
parallel run. Then rm -rf .build. Do not push. Report: delivered behavior,
changed paths, the Interrupted-vs-failed diagnosis, test results, remaining
risks.
```

## Acceptance

Kill Rafu mid-spawn: the run directory has a manifest and surfaces on
relaunch. Delete a manifest by hand: the run shows as degraded history. The
Activity feed for one failed run shows identified rows ending in Failed.
