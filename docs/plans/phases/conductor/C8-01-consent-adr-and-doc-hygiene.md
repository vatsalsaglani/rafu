# C8-01 — ADR 0018 consent amendment + doc hygiene

- **Status:** Ready. Branch: `conductor/c8-01-consent-docs` (from `main`).
  Wave 1 — runs parallel with C8-02. **Docs only. Zero code edits.**
- **Why first:** `C8-cli-and-skill-spec.md` Part 4 — "ADR amendment must
  precede any mutating code." C8-03 may not branch until this merges.

## Goal

Amend ADR 0018 with the Ensemble coordinator consent model (verbs, token,
grant, streaming, re-grant), record the answered open questions in both C8
design docs, and fix every stale statement the C8 reconnaissance found so
no later agent plans against wrong docs.

## Read first

1. `AGENTS.md`, `docs/plans/phases/conductor/README.md` (ground rules,
   preflight table).
2. `docs/plans/phases/conductor/C8-execution-plan.md` — the eight locked
   decisions this amendment encodes.
3. `docs/plans/phases/conductor/C8-coordinator-ux.md` and
   `C8-cli-and-skill-spec.md` in full.
4. `docs/decisions/0018-conductor-external-agent-orchestration.md` and
   `docs/decisions/README.md` (index + "add a superseding ADR / amendment,
   never rewrite history" rule; ADR 0016 is the amendment precedent).

## Owned paths

`docs/decisions/0018-conductor-external-agent-orchestration.md`,
`docs/decisions/README.md`,
`docs/plans/phases/conductor/{README.md,C8-coordinator-ux.md,C8-cli-and-skill-spec.md,C6-workflow-library.md,C7-polish.md}`,
`docs/references/{conductor-file-contracts.md,conductor-pipeline-engine.md,README.md}`,
this plan file's status line.

**Forbidden:** everything under `Sources/`, `Tests/`, `Package.swift`,
`script/`, `AGENTS.md`, and the C8-execution-plan decisions themselves
(you encode them; you do not re-litigate them).

## Precise edits

### 1. `docs/decisions/0018-conductor-external-agent-orchestration.md`

Append a new section after the existing Consequences, titled
`## Amendment (2026-07-26): coordinator verbs, capability token, streaming`.
Do not rewrite any existing text. The amendment must state, as decisions:

- **The coordinator model.** An external, user-installed coordinator CLI,
  launched by the user in a visible terminal tab, may drive the Ensemble
  through a new `rafu ensemble <verb>` surface riding the ADR 0009 socket.
  Hub-and-spoke: only the coordinator spawns; children may propose
  (`proposes:` artifact block) but never spawn. Nested coordinators are
  structurally impossible in v1 because only coordinator sessions receive
  the token.
- **The verb surface and its trust classes.** Read-only (no token):
  `status`, `artifact`, `await`. Token-required: `run`, `abort`, `note`,
  `grant` (reads the caller's own grant), `propose-merge` (queues a diff at
  the human gate and **never merges** — ADR 0018's gated merge-back as an
  API). Exit codes reuse `sysexits`: 0, 64 `EX_USAGE`, 65 `EX_DATAERR`,
  69 `EX_UNAVAILABLE`, 75 `EX_TEMPFAIL` (grant exhausted / timeout),
  77 `EX_NOPERM` (no or dead token).
- **The capability token.** Minted per coordinator session, injected as
  `RAFU_ENSEMBLE_TOKEN` through the existing curated-environment overlay
  (`conductor-pty-spawn-and-child-environment.md`); bound to one grant;
  in-memory only; **dies with the app — a relaunched/resumed coordinator
  must be re-granted by the user** (read-only verbs keep working so it can
  re-orient). It is a capability, not a credential: unlocks no provider,
  no secret; never logged, never persisted, never in captured PTY output,
  never in a manifest. Worker children never receive it.
- **The grant.** Set by the user at coordinator launch: max concurrent
  child runs (default 3, min-ed with the window cap), max total child
  runs, allowed CLIs/providers, optional usage ceiling (best-effort, C7
  honesty rule), optional wall-clock deadline. Exhaustion parks with exit
  75 and asks the user; it never fails silently and never continues
  silently.
- **Streaming, not polling.** `await` and event delivery use a new
  long-lived subscription connection on the existing socket (one framed
  JSON event per frame, heartbeats, bounded buffers). One-shot verbs keep
  the one-frame-per-connection contract. This amends the ADR 0009 v1
  "one frame per connection" wording to "one frame per connection for
  request/response kinds; subscription kinds hold the connection and
  stream frames".
- **CLI grammar.** `rafu ensemble` becomes the first reserved subcommand.
  Collision rule is strict: an existing filesystem entry named `ensemble`
  in the working directory makes the bare invocation an error
  (`EX_USAGE`) that names `rafu ./ensemble` as the disambiguation.
- **Coordinator placement.** The coordinator runs interactively in the
  user's checkout (no worktree, no manifest in v1); durable attribution
  lives in children's manifests via the new `startedBy` field. Nothing
  about this weakens "Rafu creates worktrees; models never do" — children
  still get Rafu-created worktrees.
- **Naming.** RafuApp internals continue the `Conductor*` prefix
  (`ConductorEnsemble*` for new types). RafuCore CLI-surface types use the
  `Ensemble*` prefix because they encode the user-visible verb namespace;
  this is a deliberate, recorded exception to the "internal symbols stay
  Conductor*" rule, scoped to `Sources/RafuCore/Ensemble/`.
- **Revisit triggers.** Mesh admission (children spawning), nested
  coordinators, token persistence across relaunch, any marketplace skill
  distribution — each requires revisiting this amendment.

### 2. `docs/decisions/README.md`

Update the ADR 0018 index row to note "amended 2026-07-26 (coordinator
verbs, capability token, streaming)" — same style as ADR 0016's row.

### 3. `docs/plans/phases/conductor/README.md`

- Fix the stale sentence "Three of the five open handoffs above are C8
  prerequisites." (currently near the end) — the handoffs are closed;
  reword to state the prerequisites are satisfied and C8 execution is
  governed by `C8-execution-plan.md`.
- In the Status table, add rows for C8-01…C8-07 (branch names from
  `C8-execution-plan.md`, status "planned"). Do not restructure the table.

### 4. `docs/plans/phases/conductor/C8-coordinator-ux.md`

- In "What this needs that does not exist yet": mark the three handoff
  rows **Closed (landed `2da406e`+`5e2ac85`)**; mark "`await` semantics"
  as **Decided: streaming** (point at the amendment).
- In "Open questions": record the answers for all five (execution-plan
  decisions 4, 1→streaming is #2, 5, 6, 7 respectively) rather than
  deleting the questions — keep the question text, append
  "**Answered (2026-07-26):** …".

### 5. `docs/plans/phases/conductor/C8-cli-and-skill-spec.md`

- §1.3 `await`: replace the "polling is the honest v1" caveat's
  *conclusion* with the streaming decision (keep the analysis, add
  "**Resolved (2026-07-26): streaming** — see ADR 0018 amendment").
- §3 worked example / §1.3 `run` JSON: add a correction note that today's
  real worktree path is `<parentOfRepo>/.rafu-worktrees/<repo>-<runID>`
  and the branch is `rafu/run-<id>` (the `ensemble/…` branch shown is
  illustrative only).
- Part 4 build order: annotate stage 1 (C6/C7 handoffs) as complete; map
  the remaining stages to plan docs C8-02…C8-07.
- Open questions 6 and 7 already carry inline answers — normalize them to
  the same "**Answered:**" format and fix the `Answwer` typo.

### 6. `docs/plans/phases/conductor/C6-workflow-library.md` and `C7-polish.md`

Update each stale status line: C6 "concurrent window integration pending
the coordinator handoff" → merged `95a51f7`, handoff closed on `main`
(`2da406e`+`5e2ac85`); C7 "coordinator integration handoffs pending" →
merged `4c42b60`, all four handoffs closed likewise.

### 7. `docs/references/conductor-file-contracts.md` and `conductor-pipeline-engine.md`

Fix the step/attempt numbering to match code (verified against
`ConductorRunController.swift` `ConductorRunEvidenceLayout` and shipped
fixtures): on-disk step directories are **1-based** (`01-advisor-a1`),
attempts are **1-based** (`-a1` first execution, `-a2` first retry).
Update every `00-…-a0` example and the "Attempt numbering" prose. Note
"corrected 2026-07-26 against `ConductorRunEvidenceLayout`" in each note's
verification line. Update `docs/references/README.md` descriptions only if
their wording repeats the wrong numbering.

## Gates

Docs-only branch: no build gates required, but run
`./script/format.sh --lint` to prove no accidental source touches, and
`git diff --stat main...HEAD` must show only the owned paths above.

## Handoff report

Delivered edits per file; decisions encoded verbatim vs. reworded;
anything you found contradicting the execution plan (STOP and report
rather than resolving it yourself); branch name; every commit message;
`git rev-parse HEAD`.

---

## Goal-mode agent prompt (copy into the worktree agent)

```
You are a phase agent for the Rafu repository, working in a dedicated git
worktree. GOAL MODE: you own the outcome end to end; do not ask for
permission between steps; finish or report precisely why you cannot.

Branch: conductor/c8-01-consent-docs. Preflight: run `git status --short
--branch` ONCE. If you are on this branch with a clean tree, proceed. If
the worktree is on detached HEAD or another branch with a clean tree, run
`git checkout conductor/c8-01-consent-docs` if it exists, else
`git checkout -b conductor/c8-01-consent-docs main`, then proceed. If the
tree is dirty with edits you did not make, STOP and report.

GOAL: land the ADR 0018 consent amendment and every doc-hygiene fix
specified in docs/plans/phases/conductor/C8-01-consent-adr-and-doc-hygiene.md.
That plan file is your complete edit list — read it first, then AGENTS.md,
docs/plans/phases/conductor/README.md (ground rules), and
docs/plans/phases/conductor/C8-execution-plan.md (the eight locked
decisions you are encoding — they are settled; never re-litigate them).

This is a DOCS-ONLY phase: you may not touch Sources/, Tests/,
Package.swift, script/, or AGENTS.md. HEADLESS ONLY — never run
build_and_run.sh, never launch Rafu.app.

DEFINITION OF DONE:
1. ADR 0018 carries the new Amendment section covering: coordinator
   model + hub-and-spoke, verb surface with trust classes and sysexits
   codes, capability token (in-memory, dies with the app, re-grant on
   relaunch, never logged/persisted), grant fields and exhaustion
   behavior, streaming-not-polling with the ADR 0009 wording amendment,
   strict subcommand collision rule, coordinator-in-checkout placement,
   the Ensemble*/Conductor* naming exception, revisit triggers.
2. docs/decisions/README.md row updated.
3. All stale statements fixed: conductor README prerequisite sentence +
   C8 status rows added; C8-coordinator-ux dependency table + all five
   open questions answered in place; C8-cli-and-skill-spec await
   resolution, worktree-path correction, build-order annotation,
   question 6/7 normalization; C6/C7 phase status lines; the 00/a0 →
   01/a1 numbering fix in conductor-file-contracts.md and
   conductor-pipeline-engine.md.
4. `git diff --stat main...HEAD` shows only the plan's owned paths;
   `./script/format.sh --lint` is clean.
5. Work is committed locally on the branch in logical commits. Never
   push, never merge, never rebase, never checkout main.

FINAL REPORT (mandatory): what you achieved per file; how you verified
it; branch name; every commit message; the last commit id from
`git rev-parse HEAD`; any contradiction you found and did NOT resolve.
```
