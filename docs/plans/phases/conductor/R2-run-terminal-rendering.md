# R2 — run terminals render readable output, not raw stream-json (F2)

- **Branch:** `conductor/r2-run-terminal-rendering` · **Wave:** 1 · **Depends:** none
- **Fixes:** finding F2 of
  [`ensemble-2026-07-29-remediation.md`](ensemble-2026-07-29-remediation.md).

## Problem

Claude Code runs are invoked with `--output-format stream-json --verbose`, so
the run's terminal tab shows raw JSON events. Nothing in Rafu consumes that
JSON (ADR 0018: captured output is evidence, not protocol). Plain text output
would be silent for the whole multi-minute step, which reads as a hang. Also,
a completed Ensemble step terminal shows the plain-terminal "Shell exited (0)
/ Restart Shell" overlay, which is meaningless for a finished run step.

## Deliverables

1. A **presentation-only** line renderer in the run output path: each
   stream-json event becomes one short human line — session init (model,
   mode), tool use ("tool: Write brief.md"), a thinking indicator, assistant
   text verbatim, and the final result/cost line. Any line that does not
   parse passes through raw. Completion detection stays artifact + exit —
   the renderer must never influence run state.
2. `logs/output.log` captures what the terminal showed (rendered lines).
3. The "Restart Shell" overlay is suppressed for Ensemble run step
   terminals; plain terminals keep it. Use the existing seam that already
   distinguishes run terminals from shell terminals (Resources naming does).
4. Tests: renderer unit tests over recorded stream-json fixtures (init, tool
   use, text, result, malformed line); a test that run state is unaffected by
   renderer failures.

## Owned paths

`Sources/RafuApp/Conductor/Run/ConductorRunOutputCapture.swift`, a new
formatter file beside it, the terminal hosting view's overlay condition, new
tests `Tests/RafuAppTests/Conductor/RunTerminalRenderingTests.swift`.
Do **not** touch adapter files (R1 owns them) — the flags stay as they are.

## Goal prompt (paste verbatim into a goal-mode agent in this worktree)

```
Read AGENTS.md, docs/plans/phases/conductor/ensemble-2026-07-29-remediation.md
(finding F2), and docs/plans/phases/conductor/R2-run-terminal-rendering.md.
You are on branch conductor/r2-run-terminal-rendering in a dedicated
worktree; obey the plan's owned paths and R-execution-plan.md's collision
table. Do NOT touch Sources/RafuApp/Conductor/Adapters/ — another worktree
owns it.

Goal: Ensemble run terminals must show readable, honest lines instead of raw
stream-json, and completed run-step terminals must not offer "Restart Shell".

Build a presentation-only formatter in the run output path
(ConductorRunOutputCapture.swift plus a new file beside it): map each Claude
stream-json event to one short human line (init: model and permission mode;
tool use: tool name and primary target; a thinking indicator; assistant text
verbatim; final result line with duration and cost). A line that fails to
parse is passed through raw, never dropped. The formatter must have zero
effect on run state — completion stays artifact-plus-clean-exit. output.log
records the rendered lines. Then suppress the Shell exited / Restart Shell
overlay for Ensemble run step terminals only, via the existing seam that
distinguishes run terminals from plain shell terminals; plain terminals are
unchanged.

Add tests in Tests/RafuAppTests/Conductor/RunTerminalRenderingTests.swift
using recorded stream-json fixture lines (take real shapes from the
remediation doc's evidence: system/init, rate_limit_event, thinking_tokens,
assistant message, result) plus a malformed line, and a test proving a
renderer error cannot change run state.

Rules: script/build.sh and script/test.sh only, one SwiftPM invocation at a
time, never poll, background long runs. Finish with format fix → format lint
→ build → parallel tests → commit; nothing may modify files after the
parallel run. Then rm -rf .build. Do not push. Report: delivered behavior,
changed paths, fixture coverage, test results, remaining risks.
```

## Acceptance

Manual plan C1 shows a working, readable terminal; `output.log` contains the
same lines; a finished step terminal offers no Restart Shell; a plain ⌃`
terminal still does.
