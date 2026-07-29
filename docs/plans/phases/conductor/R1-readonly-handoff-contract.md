# R1 — readOnly roles must be able to write their handoff artifact (F1, blocker)

- **Branch:** `conductor/r1-readonly-handoff` · **Wave:** 1 · **Depends:** none
- **Fixes:** finding F1 of
  [`ensemble-2026-07-29-remediation.md`](ensemble-2026-07-29-remediation.md)
  for Claude Code, plus the contract and fail-closed seam every adapter needs.

## Problem

`ConductorAutonomy.readOnly` maps to `--permission-mode plan` in
`ClaudeCodeAdapter.invocation` (`ClaudeCodeAdapter.swift:606-607`). Headless
plan mode denies every write and cannot be exited, so the role does its work,
writes a plan file into `~/.claude/plans/`, exits 0, and the run fails with
"exited successfully without creating its handoff artifact." Verified on a
real run (manifest `e0e353ce…` in the user's `ensemble-test` repo).

## Deliverables

1. **Contract:** redefine readOnly in `ConductorAutonomy`'s documentation:
   *no repository writes; writes inside the run's handoff directory are
   required and allowed.*
2. **Claude mapping:** probe and land an invocation that satisfies it.
   Candidate: `--permission-mode default` plus
   `--allowedTools "Write(<handoff-abs-path>/**)"` (and `Edit(…)` if needed),
   relying on headless auto-deny for every other write. Probe in a scratch
   repo with `--model claude-haiku-4-5` to keep cost near zero. Required
   probe outcomes: repo write denied; handoff write allowed; repo read
   allowed; artifact present; exit 0.
3. **Fail-closed seam:** extend the adapter surface so an adapter can declare
   readOnly unsupported, and make `WorkspaceConductorRunLauncher` refuse such
   a run **before spawning** with a message naming the vendor limitation.
   Wire the existing adapters honestly: Claude supported (new mapping);
   Codex/OpenCode/Cline **unsupported for now** (R5 probes them); Cursor
   unsupported (already documented).
4. **Docs:** add a "Read-only + handoff write" row with probe evidence to
   `docs/references/conductor-cli-capability-matrix.md`; append the
   remaining-adapter limitation to the manual test plan's known-limitations
   section (append-only).
5. **Tests:** invocation unit tests (readOnly no longer emits `plan`; the
   allowed-tools rule contains the handoff path); launcher test that an
   unsupported-readOnly role fails before spawn with the stated message.

## Owned paths

`Sources/RafuApp/Conductor/Adapters/*`, `ConductorCore.swift`,
`Run/WorkspaceConductorRunLauncher.swift`, the capability matrix,
`ensemble-manual-test-plan.md` (append-only), new tests
`Tests/RafuAppTests/Conductor/ReadOnlyHandoffContractTests.swift`.
Do not touch anything in the R-execution-plan collision table owned by
another plan.

## Goal prompt (paste verbatim into a goal-mode agent in this worktree)

```
Read AGENTS.md, docs/plans/phases/conductor/ensemble-2026-07-29-remediation.md
(finding F1), and docs/plans/phases/conductor/R1-readonly-handoff-contract.md.
You are on branch conductor/r1-readonly-handoff in a dedicated worktree; obey
that plan's owned paths and the collision table in R-execution-plan.md.

Goal: make readOnly Ensemble roles able to write their one handoff artifact,
for Claude Code, and make unsupported adapters fail before spawning.

The bug: ClaudeCodeAdapter maps autonomy .readOnly to --permission-mode plan.
Headless plan mode denies all writes and cannot be exited, so advisor roles
always fail after doing the work. The contract is: no repository writes, but
writes inside the RAFU_HANDOFF directory are required.

Do, in order:
1. Probe the real claude CLI in a throwaway git repo (never this repo, never
   the user's projects) using --model claude-haiku-4-5 and tiny prompts:
   verify that -p --permission-mode default with
   --allowedTools "Write(<handoff>/**)" allows the handoff write, denies repo
   writes, allows repo reads, and exits 0 with the artifact present. Record
   exact commands and outcomes.
2. Land the new Claude readOnly invocation per the probe.
3. Add an adapter capability so an adapter declares whether it supports the
   readOnly-plus-handoff contract; WorkspaceConductorRunLauncher must refuse
   an unsupported readOnly run BEFORE spawning, with a visible message naming
   the vendor limitation. Mark Codex, OpenCode, Cline, Cursor unsupported for
   now (plan R5 probes them later).
4. Update ConductorAutonomy's doc comment to state the contract, add the
   probe row to docs/references/conductor-cli-capability-matrix.md, and
   append the temporary limitation to ensemble-manual-test-plan.md's
   known-limitations section.
5. Add tests in Tests/RafuAppTests/Conductor/ReadOnlyHandoffContractTests.swift
   (invocation shape; launcher fail-closed path). Use FakeConductorAdapter
   patterns already in the suite where a real CLI is not needed.

Rules: script/build.sh and script/test.sh only, one SwiftPM invocation at a
time, never poll, background long runs. Finish with format fix → format lint
→ build → parallel tests → commit; nothing may modify files after the
parallel run. Then rm -rf .build. Do not push. Report: delivered behavior,
changed paths, probe evidence, test results, remaining risks.
```

## Acceptance

A real advisor run (manual plan C1–C6) completes with `handoff/brief.md`
present; an OpenCode readOnly role refuses to start with a clear message.
