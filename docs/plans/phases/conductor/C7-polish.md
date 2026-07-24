# C7 — Polish: usage-per-run, notch progress, resume, accessibility, accounting

- **Branch:** `conductor/c7-polish` (Wave C, branch after C5 merges;
  parallel with C6 — owned paths are disjoint)
- **Depends on:** C0 + C1 + C5 on `main`
- **Status:** Planned

## Mission

Close the loop with the rest of Rafu: what a run costs, where it shows up
when you're not looking at the window, how interrupted runs recover, and
proof the feature respects the accessibility and resource contracts. No new
orchestration capability lands here.

## Scope

### Usage-per-run (ties into ADR 0017 metering)

- Snapshot each enabled usage provider's reading at step start/end and
  record the delta in the run manifest per step ("this implementor step
  moved your Codex window ~N%"). Best-effort and honest: providers without
  metering, or steps too fast to resolve a delta, show nothing — never a
  fake number. Metering stays its own trust domain: the Ensemble reads
  `UsageRegistryReader` snapshots only, never provider credentials.
- Run detail canvas shows per-step and per-run cost lines when available.

### Notch companion + attention polish

- Companion strip: active-run tile (step k/n, role, attention dot when a
  gate is waiting), mutually exclusive with existing attention surfaces per
  ADR 0016's amendment pattern; peek panel row jumps to the run.
- Notification actions on gate-ready: Approve / Open Run (Approve only for
  gates explicitly marked safe-to-approve-remotely in the workflow file;
  default is Open Run).

### Resume and recovery

- App relaunch with a run mid-flight: the manifest + worktree + run dir
  are the truth. Live processes are NOT resurrected (ADR 0004/0014);
  in-flight steps are marked `interrupted`, and the run parks with verbs
  Retry step / Abort / Keep worktree. Adapter-native `--resume` modes stay
  out of scope (recorded as a future per-adapter option).
- Stale-run janitor: runs whose worktree vanished externally degrade to
  history with an explicit note, never a crash or a silent disappearance.

### Accessibility + resource accounting

- Full pass over Ensemble surfaces: VoiceOver labels/rotor order on the
  panel and timeline, Full Keyboard Access reachability for every verb,
  Reduce Motion (no decorative animation on step transitions), text-size
  resilience, no color-only state anywhere.
- Child agent processes appear attributed in the Resources surface via
  `ProcessResourceRegistry` (name = role + provider); idle Rafu with no
  active run shows zero Ensemble overhead — record Release-build evidence
  per the AGENTS.md performance rule.

## Owned paths

- `Sources/RafuApp/Conductor/Run/ConductorRunUsage*` (new),
  `.../ConductorRunRecovery*` (new)
- `Views/ConductorRunDetailCanvas.swift` (extend — C5 owned it; wave
  ordering prevents concurrent edits; C6 owns the panel, so this phase
  does NOT touch `ConductorRunsPanelView.swift`)
- Notch companion additive hunks (model + tile + peek row) — minimal, ONE
  isolated flagged commit
- `Tests/RafuAppTests/Conductor/{Usage,Recovery}*` + fixtures
- This file's status line

Forbidden: adapters, core, registry, Settings, `ConductorRunsPanelView`,
C6's Library files, `Package.swift`.

## Exit criteria

- Headless: usage-delta recording (fixture snapshots incl. the no-data
  honest path), interrupted-run recovery FSM, stale-run degradation, notch
  model unit tests.
- Deferred GUI/manual pass listed: notch tile on real notch hardware,
  VoiceOver with real VoiceOver, Release-build idle memory evidence.

## Goal-mode prompt

> /goal Implement phase C7 exactly as scoped in
> docs/plans/phases/conductor/C7-polish.md. Read that file AND
> docs/plans/phases/conductor/README.md AND
> docs/decisions/0018-conductor-external-agent-orchestration.md first, in
> that order, then AGENTS.md. First run `git status --short --branch`; you
> must be on branch conductor/c7-polish with a clean tree, and C0+C1+C5
> must be present in this branch's history — if not, STOP and report. Use
> the advisor→implementor→documentor workflow per increment. All tests run
> against FakeConductorAdapter and fixture usage snapshots — no live
> providers, no real vendor CLIs. Honesty rules: no fake cost numbers, no
> resurrected processes, interrupted runs park with explicit verbs. Obey
> the README worktree ground rules (headless gates only, commit on this
> branch, never push/merge, touch ONLY your owned paths; the notch
> companion hunks are minimal, additive, one isolated flagged commit; do
> NOT touch ConductorRunsPanelView.swift — C6 owns it this wave). Finish
> with one consolidated report: per increment — changes, files, test
> delta, deviations, evidence; then the isolated notch commit id, deferred
> GUI/manual checks (notch hardware, real VoiceOver, Release memory
> evidence), intended doc-index rows, and remaining risks.
