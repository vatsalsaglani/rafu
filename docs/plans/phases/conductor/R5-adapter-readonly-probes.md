# R5 — probe the readOnly+handoff contract on Codex, OpenCode, Cline (F1, remaining adapters)

- **Branch:** `conductor/r5-adapter-readonly-probes` · **Wave:** 2 ·
  **Depends:** R1 merged to `main` (contract, seam, matrix row format).
- **Fixes:** the remaining-adapter half of finding F1 in
  [`ensemble-2026-07-29-remediation.md`](ensemble-2026-07-29-remediation.md).

## Problem

After R1, Claude Code supports the readOnly contract (*no repository writes;
handoff-directory writes allowed*) and Codex, OpenCode, Cline, and Cursor are
declared unsupported, failing closed before spawn. This plan probes each
vendor for a real mapping and upgrades the ones that can express it.

## Probe questions per adapter

| Adapter | Current deny-all mapping | Candidate to probe |
|---|---|---|
| Codex | `--sandbox read-only` | A scoped writable root: `--sandbox workspace-write` with the handoff dir as the sandbox workspace (repo must stay readable), or a sandbox config override. |
| OpenCode | `--agent plan` | A permission/agent configuration allowing writes only under the handoff path. |
| Cline | `--plan` + `--auto-approve false` | Same question; also whether headless approval semantics allow a scoped write at all. |
| Cursor | `--mode plan` | Re-probe only if trivial; otherwise stays unsupported (existing known limitation). |

Every probe runs in a throwaway git repo with the vendor's cheapest model and
a tiny prompt. Each probe must answer: handoff write allowed? repo write
denied? repo read allowed? clean exit with artifact present?

## Deliverables

1. Probe evidence (exact commands, outcomes) recorded in the
   "Read-only + handoff write" row of
   `docs/references/conductor-cli-capability-matrix.md` for all four vendors.
2. Adapter mappings upgraded where the probe passed; `supportsReadOnly`
   (R1's seam) flipped accordingly. Where the vendor cannot express it, the
   adapter stays fail-closed and the matrix says why.
3. Invocation unit tests per upgraded adapter.
4. The manual test plan's known-limitations entry updated to the post-probe
   truth (append/amend only your entry).

## Owned paths

`Sources/RafuApp/Conductor/Adapters/{CodexAdapter,OpenCodeAdapter,ClineAdapter,CursorAdapter}.swift`,
the capability matrix, the R1 limitation entry in
`ensemble-manual-test-plan.md`, new tests
`Tests/RafuAppTests/Conductor/AdapterReadOnlyProbeTests.swift`.

## Goal prompt (paste verbatim into a goal-mode agent in this worktree)

```
Read AGENTS.md, docs/plans/phases/conductor/ensemble-2026-07-29-remediation.md
(finding F1), docs/plans/phases/conductor/R1-readonly-handoff-contract.md
(the merged contract and seam), and
docs/plans/phases/conductor/R5-adapter-readonly-probes.md. You are on branch
conductor/r5-adapter-readonly-probes in a dedicated worktree; obey the plan's
owned paths.

Goal: for Codex, OpenCode, and Cline (and Cursor only if trivial), determine
by real probes whether the vendor can express "no repository writes, but
writes allowed inside one handoff directory", then upgrade each adapter that
can and leave the rest honestly fail-closed.

Method per vendor: throwaway git repo, cheapest model, tiny prompt. Answer
four questions: handoff write allowed? repository write denied? repository
read allowed? clean exit with artifact present? Record exact commands and
outcomes. A vendor that fails any question stays unsupported — never ship a
mapping that silently grants repository write access to a readOnly role;
fail closed is the standing rule.

Then: update each upgradable adapter's invocation and its supportsReadOnly
declaration; add invocation unit tests in
Tests/RafuAppTests/Conductor/AdapterReadOnlyProbeTests.swift; record all
probe evidence in the "Read-only + handoff write" row of
docs/references/conductor-cli-capability-matrix.md; update the R1 limitation
note in ensemble-manual-test-plan.md to the new truth.

Rules: script/build.sh and script/test.sh only, one SwiftPM invocation at a
time, never poll, background long runs. Finish with format fix → format lint
→ build → parallel tests → commit; nothing may modify files after the
parallel run. Then rm -rf .build. Do not push. Report: per-vendor verdicts
with evidence, changed paths, test results, remaining risks.
```

## Acceptance

The capability matrix answers the four probe questions for all four vendors;
every upgraded adapter passes a real advisor-style run; every non-upgraded
adapter still refuses readOnly roles before spawn.
