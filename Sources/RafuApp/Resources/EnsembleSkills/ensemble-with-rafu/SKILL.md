---
name: ensemble-with-rafu
description: Orchestrate parallel agent runs in Rafu via rafu ensemble — worktrees, gates, budgets
targetsVerbVersion: 2
---

# Ensemble with Rafu

## When to use

Use this skill when you are the coordinator launched from Rafu's New Ensemble
sheet. `RAFU_ENSEMBLE_TOKEN` is present in your environment, and the repository
containing your terminal is the workspace you coordinate.

## The hard rules

- Never merge. Call `propose-merge`, then `await --state merged`; the user owns the merge gate.
- Check `grant` before every fan-out. Size the fan-out to what is left.
- Write exactly one artifact per step, at the path Rafu gave the child.
- Exit 77 means stop and report. Never retry with different arguments.
- Exit 75 means ask the user to extend the grant. Never loop.
- Bind roles explicitly. Never assume a CLI is installed or authorized.
- Dedupe against everything SEEN, not only confirmed findings.
- Write `.rafu/agents/*.md` and `.rafu/workflows/*.md` FIRST, then open with `run --plan-gate` so the user approves the plan before anything spawns.

## The loop

1. Write the agent and workflow plan files under `.rafu/`.
2. Open the workflow with `run --plan-gate`, then await the user's approval.
3. Call `grant` and size the next fan-out to its remaining limits.
4. Launch `run` calls with explicit role bindings, never above the concurrent limit.
5. Call `await --any`, read the completed run's `artifact`, judge it yourself,
   and refill only when budget remains.
6. Repeat when more work is justified. Otherwise call `propose-merge`.
7. Call `await --state merged`. The wait ends only after the user decides the
   merge gate.
8. Summarize the outcome in your own coordinator terminal.

## Failure actions

| Exit | Meaning | Required action |
|---:|---|---|
| 0 | Success | Continue. |
| 64 | Bad grammar, or a mutating verb unavailable in this Rafu | For read-only grammar, fix the call without retrying it verbatim. For a mutating verb, stop and ask the user to update Rafu; do not retry with different arguments. |
| 65 | Malformed or missing workflow, agent, run, or step data | Correct the file or identifier, re-open the plan gate when a plan file changed, then continue. |
| 69 | Rafu or the matching open workspace is unavailable | Stop and ask the user to run Rafu and open this workspace. |
| 75 | The grant is exhausted or an await timed out | Ask the user to extend the grant or timeout; never loop. |
| 77 | The token is missing/dead or a CLI is not allowed | Stop and report; never retry with different arguments. |

Read `references/verbs.md` before issuing commands,
`references/file-formats.md` before authoring plans,
`references/patterns.md` before choosing a graph shape, and
`references/troubleshooting.md` after any nonzero exit.
