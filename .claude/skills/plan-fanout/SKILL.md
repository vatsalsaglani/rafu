---
name: plan-fanout
description: >
  Turn one large piece of work into N worktree plans that independent agents
  can execute in parallel, each with exact edits and a goal-mode prompt.
disable-model-invocation: true
argument-hint: "<work to split into parallel worktree plans>"
---

Split this work into parallel worktree plans:

$ARGUMENTS

You stay the coordinator throughout. The split decision and the conflict
table are yours — do not delegate them.

## 1. Recon before deciding anything

Fan out **parallel** read-only explorers over the subsystems the work
touches, in ONE message so they run concurrently. Ask each for exact paths,
type names, and approximate line numbers — not summaries. A plan is only
worth writing if it can tell an agent *where* to edit.

Read the governing documents yourself rather than delegating them: the
active phase docs, the ADRs the work touches, and any reference note the
subsystem owns. You need this in your own context to make the split.

Verify anything the docs assert but you have not seen. Doc drift is normal:
in past runs, "open handoffs" were already closed, a reference note's
numbering contradicted the code, and a plan's five-item list was missing an
item. **Check the code, then plan against the code.**

## 2. Decide the split — by ownership, not by feature

Group work so that **each plan owns a disjoint set of files**. Feature
boundaries are a starting hypothesis; file ownership is the constraint.

When two plans need the same file:

- **A shared foundation the others build on → a small serial plan first.**
  Used when the file needs restructuring before anyone extends it (a 38-branch
  chain becoming one route enum; a shim establishing shared contracts). Keep
  it deliberately small — its job is to make the others additive.
- **Both only append → anchored regions in one file.** Name the exact
  region each plan may touch and say the other plan edits a different one.
  This works: it has survived several parallel merges with only trivial
  adjacency conflicts.
- **One creates, others consume → transfer ownership explicitly.** Record it
  in the execution plan so the consuming plans say "consume, never edit".

Produce a **conflict table** naming every shared file and its owner. Then
verify it mechanically rather than by eye:

```bash
comm -12 <(git diff --name-only main...branch-a | sort) \
         <(git diff --name-only main...branch-b | sort)
```

For plans not yet written, compare the owned-path lists in the documents.
Check the files you *know* are contended by name — a regex sweep misses a
path written differently in prose.

## 3. Write the documents

One execution plan plus one document per worktree. Use the skeleton in
[`references/plan-document.md`](references/plan-document.md) and the prompt
template in [`references/goal-mode-prompt.md`](references/goal-mode-prompt.md).

The execution plan carries: the locked decisions (with the reasoning that
closes off alternatives), the plan/branch/wave table, the wave rules, the
shared-file ownership table, the worktree commands, and a definition of done
for the set.

Each plan document must be specific enough that its agent does almost no
exploration: exact paths, exact insertion anchors, the existing types and
patterns to copy, and the tests to write. If you cannot name the file, you
have not finished recon.

## 4. Verify, register, report

- Re-run the disjointness check across the finished documents.
- Grep for stale cross-references between plans (a wave-3 plan naming a peer
  that moved to wave 2 will mislead its agent about who owns what).
- Register the set in the phases index.
- Report the worktree commands and the merge order.

## Hard rules, each learned expensively

**A plan is a hypothesis about the codebase.** Say so in the plan, and tell
the agent that if execution proves the plan wrong it should deviate and
report, not comply. Real cases: a plan said mark steps `.pending` and the
correct answer was `.aborted`; a plan named a file that did not hold the code;
a plan listed five state sites and there were six. Every one would have
shipped a defect if followed literally.

**Specify guards as source scans, not checklists.** A checklist of known
sites goes stale the moment someone adds one. A test that scans for the
*pattern* catches the addition. This is what found the sixth state site, and
what caught a verb-surface drift the moment a parallel phase landed.

**Name why the plan exists, not just what to do.** Agents weigh their effort
by what the prompt emphasises. Stating the failure being prevented is what
keeps an agent from polishing the cosmetic part and skimping the load-bearing
one.

**Shared indexes are report rows, never edits.** `docs/references/README.md`
and the ADR index belong to the coordinator; two phases editing them in one
wave collide for no reason. Plans must say "intended index row goes in your
report".

**Bound anything that could loop.** Verification rounds, retries, fan-out
size. An unbounded loop between agents burns hours on a flaky test.

## Two failure modes to write defences against

**Contention flakes read as regressions.** With several worktrees building at
once, timing-sensitive tests fail under load and pass in isolation. Every
plan must point at the isolation-based triage table and say never to "fix" a
starvation flake. Three separate agents hit this in one wave.

**Silent scope creep into unowned files.** The handoff-not-halt rule is the
defence: do everything independent of the blocked seam, then report the exact
file, line, and a proposed diff. A plan that does not say this gets either a
scope violation or a phase that delivers nothing.

## Inject the repository's standing rules

Every generated prompt must carry these, drawn from `AGENTS.md` and the
conductor ground rules — do not re-derive them, and re-read those files in
case they have changed:

- Preflight is self-healing: detached HEAD or wrong branch with a clean tree
  → fix it and proceed, saying so. Dirty tree with someone else's edits → STOP.
- Prerequisite verification with an explicit STOP condition naming the symbol
  or file that must already exist.
- Gates: build 0 warnings; parallel suite per stage; serial suite ONCE at the
  end; format `--fix` then `--lint`. Final ordering is format → build →
  parallel → commit, with nothing modifying a file afterwards.
- Headless only — except where launching is the thing under test, in which
  case say so explicitly. Local builds are Rafu Lightning; never `pkill` or
  `pgrep` a bare `Rafu`.
- Never poll: background long work and wait for the notification.
- `rm -rf .build` as the last step in a worktree.
- Commit locally in verified stages; never push, merge, rebase, or checkout
  `main`.
- The final report must include branch name, every commit message, and
  `git rev-parse HEAD`.

## Do not

- Do not write a plan you have not grounded in the code.
- Do not split work so finely that plans spend more time coordinating than
  implementing.
- Do not let two plans own one file without an anchor or a transfer.
- Do not create worktrees or launch agents yourself — report the commands and
  let the user start them.
- Do not claim a conflict check passed unless you ran it.
