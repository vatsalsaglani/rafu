# Ensemble — parallel worktree execution plan

Parent decision: [ADR 0018](../../../decisions/0018-conductor-external-agent-orchestration.md)
(orchestrate external agent CLIs, embed none; delegated auth; file-based
handoffs; Rafu-owned worktrees; gated merge-back). This folder splits the
Ensemble into EIGHT phases (C0–C7) engineered for parallel execution by
independent agents in separate git worktrees, then local merges back into
`main` by the coordinator.

**Naming (ADR 0018, Naming section):** the feature was built as "the
Conductor" and renamed **Ensemble** on 2026-07-25 (conductor.build is an
existing product in this category). User-visible strings and doc prose say
Ensemble; internal `Conductor*` Swift symbols, this folder's path, the
`conductor/*` branch names, and `conductor-*` note filenames deliberately
keep the historical prefix. Phase agents: never put "Conductor" in a
user-facing string; never rename existing `Conductor*` symbols.

Supported CLI roster (all with model selection): **Claude Code, Codex,
OpenCode, Cline, Kimi CLI, Gemini CLI, Cursor CLI.** Gemini and Cursor are
best-effort tier (the user may not have active access); their adapters must
degrade honestly.

## Dependency graph

```
C0 (shared shim + contracts) ── MUST merge to main FIRST, serial, blocks everything
 ├─ Wave A (parallel, branch from main after C0 merges):
 │    C1  single-role run engine (worktree lifecycle, PTY execution,
 │        handoff capture, diff gate) — uses the C0 fake adapter, no real CLIs
 │    C2  adapters: Claude Code + Codex (reference adapters + model UX)
 │    C3  adapters: OpenCode + Cline + Kimi CLI
 │    C4  adapters: Gemini CLI + Cursor CLI (best-effort tier)
 ├─ Wave B (serial after C0 AND C1 merge):
 │    C5  pipelines: workflow execution, gates, runs navigator + run
 │        timeline detail canvas
 └─ Wave C (parallel, branch from main after C5 merges):
      C6  workflow library: multiple workflows, global+repo scope,
      │   bundled templates, picker, concurrent runs
      C7  polish: usage-per-run, notch companion progress, resume,
          accessibility, process/memory accounting
```

Within a wave, phases merge in ANY order — owned paths are disjoint by
construction. C2–C4 are useful the moment C1 lands (real CLI in a real run),
but do not depend on C1 to build or test.

## The zero-conflict rule (why this fans out safely)

C0 creates EVERYTHING shared: the Ensemble core (IDs, agent/workflow/run
models, autonomy levels, the adapter protocol, frontmatter parsers, run
store), the adapter registry listing all seven CLIs, one compiling STUB
adapter file per CLI plus a test-only fake adapter, the `.rafu/` directory
conventions, the Settings "Agents" surface (registry-driven), the `.runs`
navigator enum case with a placeholder panel, and the terminal
process-spec seam (spawn an arbitrary executable + argv + cwd + env in a
terminal tab instead of a login shell). After C0:

- C2/C3/C4 ONLY rewrite the adapter stub files they own under
  `Sources/RafuApp/Conductor/Adapters/` and add their own tests/fixtures
  under `Tests/RafuAppTests/Conductor/`.
- C1 ONLY adds run-engine files under `Sources/RafuApp/Conductor/Run/` and
  fills the C0-stubbed engine seams named in its phase doc.
- C5 ONLY rewrites the C0 placeholder panel/detail view stubs and adds
  workflow-engine files.

### Test-file ownership (set by C0)

Each adapter phase owns the per-adapter test file matching its adapter:
`Tests/RafuAppTests/Conductor/<Name>AdapterTests.swift` (C0 ships each with a
stub-honesty test and a model-discovery-consistency assertion; the owning
phase rewrites it). The remaining conductor test files —
`ConductorCoreTests.swift`, `ConductorRegistryTests.swift`,
`ConductorTerminalSpecTests.swift`, `ConductorSettingsTests.swift` — are
**integration-owned**. A failure in one of them is a STOP-AND-REPORT, never a
fix-it-yourself: they assert contracts (roster completeness, the child
environment, the terminal seam mapping) that exist to catch exactly the kind
of drift a phase agent would otherwise paper over.

A phase must NEVER touch: `Package.swift`, `ConductorCore.swift`,
`ConductorAdapterRegistry.swift`, `WorkspaceSession.swift` (beyond seams a
phase doc explicitly assigns), the Settings files, another phase's adapter or
test files, `AGENTS.md`, or `docs/` outside its own phase file's status line.
If an agent believes a shared file needs changing, it STOPS and reports the
need in its handoff instead of editing it.

## Worktree agent ground rules (every phase prompt includes these)

- You are on a dedicated worktree branch. Commit your work ON THIS BRANCH in
  verified stages. Never push, never merge, never checkout `main`, never
  rebase.
- Gates per stage: `swift build` 0 warnings; `swift test` AND
  `swift test --no-parallel` green; `./script/format.sh --fix` then
  `--lint` clean. HEADLESS ONLY — do NOT run `build_and_run.sh`, do not
  launch or kill `Rafu.app` (integrated GUI passes happen on `main` after
  merge).
- Zero-warning gates are only meaningful on files that actually recompiled:
  incremental `swift build` silently skips (and therefore hides) warnings in
  unchanged files. A fresh worktree's first build is clean and re-emits
  everything — a warning that "appears" there but not on `main` is a masked
  baseline warning, not phase fallout. Report it to the coordinator (who owns
  the fix on `main`); never fix an unowned file to satisfy the gate.
- Adapter phases (C2–C4): treat the invocation shapes in your phase doc as
  HYPOTHESES. Probe the installed CLI (`<cli> --help`, subcommand help,
  version output) before coding; if a CLI is not installed in your
  environment, implement against the documented shape, mark the adapter
  `unverified`, and record the exact probe commands the user must run in
  your handoff. Never guess silently.
- Security invariants (non-negotiable, from ADR 0018): argv arrays only,
  never shell strings; minimal explicit child env; no inference credentials
  read, stored, or forwarded — auth status probing reads presence/expiry
  metadata only, never token values; prompts, artifacts, and captured CLI
  output live under `.rafu/runs/` and are never written to Rafu's own logs;
  child pids register with `ProcessResourceRegistry`; `git worktree remove`
  never uses `--force`. No `@unchecked Sendable`. `nonisolated` members live
  in PRIMARY type bodies, never bare extensions (see
  `docs/references/nonisolated-extension-isolation-trap.md`).
- Follow the advisor→implementor→documentor flow inside the phase (all of
  these are non-trivial): advisor brief first, then implement, then the
  documentor writes note/ADR files — but never shared doc indexes; intended
  index rows go in the final report.

## Preflight and stop conditions (learned from C1 and C5)

Two failure modes wasted real time in Wave A/B. Both are prompt/process bugs,
not agent mistakes — every phase prompt now carries the fixes below.

### Preflight is SELF-HEALING, not a tripwire

The worktree tooling frequently lands a new worktree in **detached HEAD**
(`## HEAD (no branch)`). That is a setup detail, not a reason to refuse work.
Run each check ONCE and act:

| Condition | Action |
|---|---|
| On the phase branch, tree clean | Proceed. |
| Detached HEAD or wrong branch, tree clean | **Fix it yourself and proceed:** `git checkout <branch>` if it exists, else `git checkout -b <branch> main`. Say what you did in the report. |
| Tree dirty with edits you did not make | STOP — that is someone else's in-flight work. |
| A prerequisite phase is missing from history | STOP and name what is missing. |

**Never re-run an unchanged read-only check hoping for a different answer.** A
second `git status` cannot contradict the first. C1 and C5 each burned three
identical checks before declaring "blocked" — one check, one decision.

### A shared-file need is a HANDOFF, not a halt

Phases are forbidden from editing shared/unowned files, and the coordinator
(working on `main`) owns those changes. When you discover that your phase needs
one — a signature change, a new seam, a fix in a file you do not own:

1. **Do every part of the phase that does NOT depend on it, first.** Land it in
   verified, committed stages.
2. Then report the need with: the exact file and line, why the phase cannot
   proceed without it, and a **concrete proposed signature or diff**.
3. Only stop entirely if the blocked seam is genuinely a prerequisite for
   *everything* in the phase — and say so explicitly.

**Never end a phase with zero commits when independent work existed.** C5's
seam report was correct and well-evidenced, but it delivered nothing runnable;
the coordinator then implemented the whole phase from scratch. Partial delivery
plus a precise handoff is always better than a clean halt.

### Warnings and failures you did not cause

- A warning in a file with no diff from your phase is a masked baseline
  warning (see the ground rules above): report it, never fix it, never let it
  block your gate.
- A test failing in an integration-owned file is a STOP-AND-REPORT.
- A test that fails once under parallel `swift test` but passes under
  `--no-parallel` and on re-run is scheduler starvation, not your regression —
  note it and move on.

## Merge protocol (coordinator, on `main`)

When the user reports "phase Cn is done on branch `<branch>`":

1. `git diff main...<branch> --stat` — verify only owned paths changed.
2. Run all gates on the branch tip.
3. `git merge --no-ff <branch>` into `main`; resolve nothing silently — any
   conflict outside trivial test-count noise means an owned-paths violation
   and goes back to the phase agent.
4. Re-run gates on `main`; for phases with UI surface (C0, C1, C5, C6, C7)
   run the staged-app GUI pass now.
5. Record the merge in this README's status table.

## Worktree creation (main checkout, after C0 merges)

```bash
git worktree add ../rafu-conductor-runs     -b conductor/c1-single-role-runs
git worktree add ../rafu-conductor-claude   -b conductor/c2-adapters-claude-codex
git worktree add ../rafu-conductor-open     -b conductor/c3-adapters-opencode-cline-kimi
git worktree add ../rafu-conductor-best     -b conductor/c4-adapters-gemini-cursor
# after C1 merges:
git worktree add ../rafu-conductor-pipes    -b conductor/c5-pipelines
# after C5 merges:
git worktree add ../rafu-conductor-library  -b conductor/c6-workflow-library
git worktree add ../rafu-conductor-polish   -b conductor/c7-polish
```

## Status

| Phase | File | Branch | Status |
|---|---|---|---|
| C0 | [C0-shim.md](C0-shim.md) | main (serial) | Merged (all gates + GUI pass green) |
| C1 | [C1-single-role-runs.md](C1-single-role-runs.md) | main | Merged 2026-07-25 (ac3f1ab + 7b4bba0; run engine + output capture + eager reload seams) |
| C2 | [C2-adapters-claude-codex.md](C2-adapters-claude-codex.md) | `conductor/c2-adapters-claude-codex` | Merged 2026-07-24 (`7a2ab62`; both CLIs probe-verified) |
| C3 | [C3-adapters-opencode-cline-kimi.md](C3-adapters-opencode-cline-kimi.md) | `conductor/c3-adapters-opencode-cline-kimi` | Merged 2026-07-24 (`b2ed160`; OpenCode + Cline verified, Kimi unverified/absent) |
| C4 | [C4-adapters-gemini-cursor.md](C4-adapters-gemini-cursor.md) | `conductor/c4-adapters-gemini-cursor` | Merged 2026-07-24 (`4fa45cb`; Cursor verified logged-out, Gemini unverified/absent) |
| C5 | [C5-pipelines.md](C5-pipelines.md) | main | Implemented on main (commits fc33a99/c5c83de/a89309a/c58eef1; coordinator-implemented after stop-and-report; 0 warnings, 1479 tests, GUI verified) |
| C6 | [C6-workflow-library.md](C6-workflow-library.md) | `conductor/c6-workflow-library` | Merged 2026-07-25 (`95a51f7`; owned work complete — 1 integration handoff open, see below) |
| C7 | [C7-polish.md](C7-polish.md) | `conductor/c7-polish` | Merged 2026-07-25 (`4c42b60`; owned work complete — 4 integration handoffs open, see below) |
| C8-01 | [C8-01-consent-adr-and-doc-hygiene.md](C8-01-consent-adr-and-doc-hygiene.md) | `conductor/c8-01-consent-docs` | Planned |
| C8-02 | [C8-02-ipc-streaming-and-readonly-verbs.md](C8-02-ipc-streaming-and-readonly-verbs.md) | `conductor/c8-02-ipc-streaming` | Planned |
| C8-03 | [C8-03-capability-token-and-mutating-verbs.md](C8-03-capability-token-and-mutating-verbs.md) | `conductor/c8-03-mutating-verbs` | Planned |
| C8-04 | [C8-04-plan-gate-and-propose-merge.md](C8-04-plan-gate-and-propose-merge.md) | `conductor/c8-04-plan-gate` | Planned |
| C8-05 | [C8-05-skill-pack-and-settings.md](C8-05-skill-pack-and-settings.md) | `conductor/c8-05-skill-pack` | Planned |
| C8-06 | [C8-06-graph-canvas.md](C8-06-graph-canvas.md) | `conductor/c8-06-graph-canvas` | Planned |
| C8-07 | [C8-07-guided-onboarding.md](C8-07-guided-onboarding.md) | `conductor/c8-07-onboarding` | Planned |

Merged-main gates after C6+C7: 0 warnings, 1515 tests green parallel and
serial, lint clean, staged-app GUI verify passed.

## Coordinator integration handoffs (C6 + C7) — ALL CLOSED

Both Wave C phases correctly stopped at files they do not own and delivered
their owned work plus a precise proposed diff (the handoff-not-halt rule
above, working as intended). All five landed on `main` in
`2da406e` + `5e2ac85` (2026-07-25), so C6/C7's features are now end-to-end
rather than engine-complete:

| # | From | Landed |
|---|---|---|
| 1 | C6 | `WorkspaceSession.conductorConcurrentRuns` + `workflowController(forRunID:)`; menu, palette, canvas, and panel launch all route through it. The New Run guard became **cap-aware** (`canStartConductorWorkflowRun`) — the proposed `!isInFlight` guard would have kept concurrency permanently unreachable. Coordinator forwards gate events; the notch companion derives from every engine. |
| 2 | C7 | `ConductorRunManifest.Step.usage`; snapshot before launch, record on EVERY terminal outcome (a failed step still consumed quota); per-step + run-total lines in the canvas; nothing rendered when metering resolved nothing. |
| 3 | C7 | `RunStepStatus.interrupted` (stable envelope) + `recoveryNote`; janitor pass in `reloadRuns()` persisted through the write queue; `restoreInterrupted` rebuilds the plan from the manifest itself, and retry reuses the interrupted attempt's persisted `prompt.md` in a fresh `-aN` directory. |
| 4 | C7 | `[gate:remote]` grammar, snapshotted per step so editing a workflow file cannot retroactively authorize an open gate; typed `ConductorGateReadyEvent` drives Open Run / Approve notification categories; the center re-checks the manifest before approving; companion tile suppresses the duplicate drop-down. |
| 5 | C7 | `TerminalProcessSpec.resourceAttribution`; `.agent` process kind rendering as "Ensemble Agent" named `role • Vendor`; login-shell path unchanged and registration still PID-gated. |

Post-integration gates: 0 warnings, **1539 tests** green parallel and serial,
lint clean, no `@unchecked Sendable` or logging in Conductor sources.

**What a human still has to verify:**
[`ensemble-manual-test-plan.md`](ensemble-manual-test-plan.md) — the checks
headless tests cannot make (the Revise flow actually carrying an edited
artifact forward, notification action sets, notch hardware, VoiceOver,
interrupted-run recovery across a real relaunch).

Each phase document ends with its self-contained goal-mode prompt (works in
Claude Code or Codex).

Beyond C7: [`orchestration-gap-analysis.md`](orchestration-gap-analysis.md)
compares the shipped engine against the user's real multi-CLI orchestration
loop (dynamic planning, fan-out DAGs, coordinator-driven merges) and sketches
the candidate C8 (coordinator-agent route: `rafu ensemble` IPC verbs + a
published skill + a bounded-budget consent model, amending ADR 0018). The
user accepted Route B on 2026-07-25;
[`C8-coordinator-ux.md`](C8-coordinator-ux.md) designs the resulting user
experience — no chat UI (the terminal tab is the conversation), a guided
entry point that makes agent/workflow files an output rather than a
prerequisite, a live graph canvas projected from the manifest, and
hub-and-spoke coordination with a bounded grant.
[`C8-cli-and-skill-spec.md`](C8-cli-and-skill-spec.md) specs the concrete
surface: the `rafu ensemble` verb set with JSON shapes and exit codes, the
run-scoped capability token that authorizes spawning, the
`ensemble-with-rafu` skill pack, three worked orchestration examples, and a
build order. These documents remain the design rationale; the C6/C7
prerequisites are satisfied, and C8 execution is governed by
[`C8-execution-plan.md`](C8-execution-plan.md).

**C8 is now planned for execution:**
[`C8-execution-plan.md`](C8-execution-plan.md) locks the open decisions
(streaming `await`, strict subcommand collision, re-grant on relaunch,
coordinator-in-checkout, interactive graph canvas) and splits the work into
seven worktree plans across four waves — `C8-01` … `C8-07`, branches
`conductor/c8-01-consent-docs` through `conductor/c8-07-onboarding`. Each
plan document ends with its self-contained goal-mode agent prompt; C8-01
owns updating the stale handoff wording above.

**Agent Terminals (AT) follow C8:**
[`AT-execution-plan.md`](AT-execution-plan.md) plans the muxy-style agent
terminal — any discovered + authed CLI one action away from an interactive
terminal session with agent identity in the chrome — and its single honest
Ensemble seam (capability decided at spawn: same sheet, a grant toggle
routes through the coordinator launcher). `AT-01`
(`conductor/at-01-agent-terminals`) **runs in C8 wave 1, starting now** —
it owns the agent-icon catalog and the per-CLI interactive-launch probe
table that C8-06/C8-03 consume; `AT-02`
(`conductor/at-02-ensemble-bridge`) follows C8 wave 3 + AT-01. Plus
ADR 0021.
