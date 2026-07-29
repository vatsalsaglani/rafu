# R6 — Single Role runs get provider and model overrides (F6)

- **Branch:** `conductor/r6-single-role-overrides` · **Wave:** 2 ·
  **Depends:** R1 merged (launcher refusal surface must exist first so the
  picker can disable unsupported provider choices honestly).
- **Fixes:** finding F6 of
  [`ensemble-2026-07-29-remediation.md`](ensemble-2026-07-29-remediation.md).

## Problem

The New Ensemble Run canvas's **Workflow** door supports a model override
(manual plan D2). The **Single Role** door offers only agent file, task
prompt, and base reference — provider and model come silently from the agent
file's frontmatter. The 2026-07-29 run recorded `model: ""` (rendered as
"CLI default"), with no way to choose otherwise without editing the file.

## Deliverables

1. Provider and model controls on the Single Role door, defaulting to the
   agent file's frontmatter values. An override applies to **this run only**
   — the agent file is never edited — and is recorded in the run manifest's
   step binding, exactly as the Workflow door's override is.
2. Reuse the Workflow door's existing picker components so the two doors
   cannot drift (model list = curated + CLI-discovered + free-text, per the
   adapter's model source rules).
3. Availability honesty: providers that are not installed / not signed in /
   readOnly-unsupported (for a readOnly agent file) are disabled with a
   stated reason — glyph plus text, matching the New Ensemble canvas rules
   (manual plan M2), never color alone.
4. Tests: override plumbing lands in the manifest binding; default-from-
   frontmatter; the file is untouched after an overridden run.

## Owned paths

`Sources/RafuApp/Conductor/Run/ConductorNewRunModel.swift`, the New Run
canvas view files for the Single Role door, new tests
`Tests/RafuAppTests/Conductor/SingleRoleOverrideTests.swift`. Reused picker
components are consumed, not redesigned — if a shared component needs a
change, stop and report.

## Goal prompt (paste verbatim into a goal-mode agent in this worktree)

```
Read AGENTS.md, docs/plans/phases/conductor/ensemble-2026-07-29-remediation.md
(finding F6), and docs/plans/phases/conductor/R6-single-role-overrides.md.
You are on branch conductor/r6-single-role-overrides in a dedicated worktree;
obey the plan's owned paths. Shared picker components are consumed, not
redesigned — stop and report if one needs changing.

Goal: the Single Role door of the New Ensemble Run canvas gets provider and
model override controls, at parity with the Workflow door's model override.

Requirements: defaults come from the selected agent file's frontmatter; an
override applies to this run only and never edits the agent file; the chosen
binding (provider, model, or explicit CLI-default) is recorded in the run
manifest exactly as the Workflow door records overrides. Reuse the Workflow
door's picker components so the doors cannot drift. Providers that are not
installed, not signed in, or that do not support readOnly when the selected
agent file is readOnly, are disabled with glyph plus stated reason — never
color alone, matching the M2 rules in ensemble-manual-test-plan.md. Keyboard
reachability for every new control; panel content pins to the top (AGENTS.md
alignment rule).

Add tests in Tests/RafuAppTests/Conductor/SingleRoleOverrideTests.swift:
frontmatter defaults, override recorded in the binding, agent file untouched
after an overridden run. Use the FakeConductorAdapter patterns already in
the suite.

GUI change: verify with ./script/build_and_run.sh and describe the manual
check steps in your report (second window, keyboard-only pass) — do not
drive the GUI with synthetic input.

Rules: script/build.sh and script/test.sh only, one SwiftPM invocation at a
time, never poll, background long runs. Finish with format fix → format lint
→ build → parallel tests → commit; nothing may modify files after the
parallel run. Then rm -rf .build. Do not push. Report: delivered behavior,
changed paths, test results, manual check steps, remaining risks.
```

## Acceptance

Single Role door shows provider + model with frontmatter defaults; an
overridden run's manifest records the override; the agent file is byte-
identical afterwards; disabled providers state why, in text.
