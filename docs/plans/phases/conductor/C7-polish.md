# C7 — Polish: usage-per-run, notch progress, resume, accessibility, accounting

- **Branch:** `conductor/c7-polish` (Wave C, branch after C5 merges;
  parallel with C6 — owned paths are disjoint)
- **Depends on:** C0 + C1 + C5 on `main`
- **Status:** Merged `4c42b60`; all four coordinator integration handoffs
  closed on `main` (`2da406e` + `5e2ac85`)

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

/goal Implement phase C7 exactly as scoped in
docs/plans/phases/conductor/C7-polish.md. Read that file AND
docs/plans/phases/conductor/README.md (including its "Preflight and stop
conditions" section — it is binding) AND
docs/decisions/0018-conductor-external-agent-orchestration.md first, in
that order, then AGENTS.md.

PREFLIGHT — run each check ONCE and act; do not re-run an unchanged
read-only check hoping for a different answer. Run `git status --short
--branch`. If you are on conductor/c7-polish with a clean tree, proceed.
If you are in detached HEAD or on another branch and the tree is CLEAN,
fix it yourself and proceed: `git checkout conductor/c7-polish` if that
branch exists, else `git checkout -b conductor/c7-polish main` — then say
what you did in your report. STOP only if (a) the tree is dirty with
edits you did not make, or (b) C0+C1+C5 are missing from history
(Sources/RafuApp/Conductor/Run/ConductorWorkflowController.swift and a
real Views/ConductorRunDetailCanvas.swift must exist).

Use the advisor→implementor→documentor workflow per increment. All tests
run against FakeConductorAdapter and fixture usage snapshots — no live
providers, no real vendor CLIs. Honesty rules: no fake cost numbers, no
resurrected processes, interrupted runs park with explicit verbs.
User-facing strings say "Ensemble", never "Conductor"; new internal
symbols keep the Conductor* prefix (ADR 0018 Naming). Obey the README
worktree ground rules (headless gates only, commit on this branch in
verified stages, never push/merge, touch ONLY your owned paths; the notch
companion hunks are minimal, additive, one isolated flagged commit; do
NOT touch ConductorRunsPanelView.swift — C6 owns it this wave).

IF YOU NEED A FILE YOU DO NOT OWN (a run-engine signature, a usage or
notch seam, anything outside your owned paths): that is a HANDOFF to the
coordinator, not a halt. First complete and commit every part of the
phase that does NOT depend on it — the four scope areas (usage-per-run,
notch/attention, resume/recovery, accessibility+accounting) are largely
independent, so a block in one is never a block in all — then report the
need with the exact file/line, why it is required, and a concrete
proposed signature or diff. Do not end this phase with zero commits when
independent work existed. A warning or test failure in a file your phase
never touched is not yours: report it, do not fix it, do not let it block
your gate.

Finish with one consolidated report: per increment — changes, files, test
delta, deviations, evidence; then any coordinator handoffs (with proposed
diffs), the isolated notch commit id, deferred GUI/manual checks (notch
hardware, real VoiceOver, Release memory evidence), intended doc-index
rows, and remaining risks.
